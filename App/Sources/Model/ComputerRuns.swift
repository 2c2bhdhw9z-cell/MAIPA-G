import AgentCore
import Foundation

/// Agent work runs on the owner's Linux computer (owner rule, 11 November 2026: "Nothing should
/// run on GitHub… run on the Linux VM that I have constantly going"). This is the phone's side:
/// finding the computer, making sure MAIPA-G's runner for this app build is on it, and the keys a
/// run needs. GitHub only builds the app.
@MainActor
enum ComputerRuns {
    /// How a chat file reaches the computer: it goes up once to MAIPA-G-data's private files
    /// release (named by its SHA-256, the same name saving uses, so it is never stored twice), and
    /// the computer downloads it from the short-lived address GitHub gives. No token goes there.
    static func chatFileLink(app: AppModel) -> ChatFileLink {
        let store = app.attachmentStore
        let github = app.github.client
        let dataRepo = app.sync.repo
        return { attachment in
            guard let github, let dataRepo else {
                throw ToolInputError("Files reach the computer through GitHub and MAIPA-G's private data repo. Connect GitHub in Settings and let saving set up first.")
            }
            let file = try store.fileURL(for: attachment)
            let name = try Hashing.sha256Hex(fileAt: file) + ".bin"
            let releaseID = try await github.filesRelease(dataRepo)
            let asset: GitHubClient.ReleaseAsset
            if let existing = try await github.releaseAssets(dataRepo, releaseID: releaseID).first(where: { $0.name == name && $0.isUploaded && $0.size == attachment.bytes }) {
                asset = existing
            } else {
                asset = try await github.uploadReleaseAsset(dataRepo, releaseID: releaseID, name: name, file: file)
            }
            return try await github.releaseAssetLink(dataRepo, assetID: asset.id)
        }
    }

    /// The commit this app was built from; the runner on the computer is that same code.
    static var revision: String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "MAIPAGReviewedRevision") as? String,
              VMControl.isRevision(value.lowercased()) else { return nil }
        return value.lowercased()
    }

    enum Readiness {
        case ready(VMControl)
        /// Why the computer can't take work right now, in words for the chat.
        case unavailable(String)
    }

    /// The computer, with the runner installed. A first install (or a build there) goes on in the
    /// background on the computer; until it finishes, work runs on the phone and the chat says so.
    static func prepare(app: AppModel) async -> Readiness {
        guard app.connectors.hasConfiguredComputer else { return .unavailable("no chat computer is set up in Settings") }
        guard let revision else { return .unavailable("this app build doesn't say which runner it needs") }
        guard let control = await app.connectors.ensureComputerSession(), control.commandTool != nil else {
            return .unavailable("the chat computer couldn't be reached")
        }
        let vm = VMControl(computer: control)
        do {
            switch try await AgentLoop.bounded(seconds: 45, label: "Checking MAIPA-G's runner on the computer", { try await vm.ensureRunner(revision: revision) }) {
            case .ready:
                return .ready(vm)
            case .installing(let step):
                return .unavailable("MAIPA-G's runner is still being installed on it" + (step.map { " (\($0))" } ?? ""))
            case .failed(let reason):
                return .unavailable("installing MAIPA-G's runner on it failed: \(reason)")
            }
        } catch {
            return .unavailable("the chat computer didn't answer: \(ErrorExplainer.explain(error).message)")
        }
    }

    /// The keys a run needs. They go to the computer in a file only its user can read, which the
    /// runner deletes as soon as it has read them; they are never put in a command, a log or the chat.
    static func secrets(app: AppModel, githubToken: String?) -> VMSecrets {
        var connectorSecrets: [String: String] = [:]
        if let json = app.connectors.autonomousSecretsJSON(),
           let values = try? JSONDecoder().decode([String: String].self, from: Data(json.utf8)) {
            connectorSecrets = values
        }
        return VMSecrets(
            openRouterKey: app.openRouter.autonomousSecretKey,
            providers: app.openRouter.readyExternalProviders,
            githubToken: githubToken,
            dataToken: githubToken,
            connectors: app.connectors.computerRunConnectors(),
            connectorSecrets: connectorSecrets
        )
    }

    /// A GitHub token for the computer with at least 50 minutes left (they last about an hour).
    /// The phone hands a new one over every 40 minutes while it follows a run, so the computer is
    /// never left holding one that has run out.
    static func githubToken(app: AppModel) async -> String? {
        guard let session = app.github.session else { return nil }
        return try? await session.installationToken(validFor: 50 * 60)
    }

    /// The run id for a reply: tied to the reply's message, so a run is only ever picked up again
    /// for the reply it belongs to.
    static func runID(forReply messageID: UUID) -> String { "turn-" + messageID.uuidString.lowercased() }
}
