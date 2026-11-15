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
        let account = app.github
        let sync = app.sync
        return { attachment in
            // Looked up when the file is sent, not when the reply started.
            guard let github = await account.client else {
                throw ToolInputError("GitHub isn't connected in MAIPA-G (Settings → GitHub), and files reach the computer through it.")
            }
            guard let dataRepo = await sync.dataRepository else {
                throw ToolInputError("Saving to MAIPA-G-data isn't set up on this phone yet (Settings → Saving), and files reach the computer through it.")
            }
            let file = try store.fileURL(for: attachment)
            let name = try Hashing.sha256Hex(fileAt: file) + ".bin"
            let releaseID = try await github.filesRelease(dataRepo)
            let asset: GitHubClient.ReleaseAsset
            if let existing = try await github.releaseAssets(dataRepo, releaseID: releaseID).first(where: { $0.name == name && $0.isUploaded && $0.size == attachment.bytes }) {
                asset = existing
            } else {
                do {
                    asset = try await github.uploadReleaseAsset(dataRepo, releaseID: releaseID, name: name, file: file)
                } catch let error as GitHubAPIError where error.status == 409 {
                    // Saving was uploading the same file and its unfinished copy was removed.
                    asset = try await github.uploadReleaseAsset(dataRepo, releaseID: releaseID, name: name, file: file)
                }
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

    /// The computer, with the runner installed. Every app build needs its own runner, which goes
    /// on in the background on the computer (held awake, so the 16 MB download takes seconds).
    /// `waitForInstall`: how long to wait for an install that is under way, checking every few
    /// seconds and telling `progress` what step it's on, before giving up. A reply waits, the way
    /// Kiro's session setup does; it used to go straight to the phone, and the phone then froze
    /// with the app (14 November 2026). `keepWaiting` returning false ends the wait (Stop).
    static func prepare(
        app: AppModel,
        waitForInstall: TimeInterval = 0,
        keepWaiting: @MainActor () -> Bool = { true },
        progress: @MainActor (String?) -> Void = { _ in }
    ) async -> Readiness {
        guard app.connectors.hasConfiguredComputer else { return .unavailable("no chat computer is set up in Settings") }
        guard let revision else { return .unavailable("this app build doesn't say which runner it needs") }
        guard let control = await app.connectors.ensureComputerSession(), control.commandTool != nil else {
            return .unavailable("the chat computer couldn't be reached")
        }
        let vm = VMControl(computer: control)
        let giveUpAt = Date().addingTimeInterval(waitForInstall)
        while true {
            let state: VMControl.RunnerState
            do {
                state = try await AgentLoop.bounded(seconds: 45, label: "Checking MAIPA-G's runner on the computer", { try await vm.ensureRunner(revision: revision) })
            } catch {
                return .unavailable("the chat computer didn't answer: \(ErrorExplainer.explain(error).message)")
            }
            switch state {
            case .ready:
                return .ready(vm)
            case .failed(let reason):
                return .unavailable("installing MAIPA-G's runner on it failed: \(reason)")
            case .installing(let step):
                guard Date() < giveUpAt, keepWaiting(), !Task.isCancelled else {
                    return .unavailable("MAIPA-G's runner for this app build is still being installed on it" + (step.map { " (\($0))" } ?? ""))
                }
                progress(step)
                try? await Task.sleep(nanoseconds: 4_000_000_000)
            }
        }
    }

    /// Installs this app build's runner on the computer ahead of the first reply: when the app
    /// opens and when it comes back to the front (at most every 10 minutes). One check starts the
    /// install, which then carries on by itself on the computer.
    static func installRunnerAhead(app: AppModel) {
        guard app.connectors.hasConfiguredComputer, revision != nil, !PreviewScenes.isActive else { return }
        if let last = lastAhead, Date().timeIntervalSince(last) < 600 { return }
        lastAhead = Date()
        Task { @MainActor in
            if case .unavailable = await prepare(app: app) {
                // Not ready yet: the next foreground checks again rather than waiting 10 minutes.
                lastAhead = nil
            }
        }
    }

    private static var lastAhead: Date?

    /// A token for MAIPA-G-data only (its files and releases), so a reply on the computer can put
    /// big files there for the phone and keep the chat saved while the phone is away.
    static func dataToken(app: AppModel, repo: RepoRef) async -> String? {
        guard let session = app.github.session else { return nil }
        return try? await session.contentsToken(forRepository: repo.name).token
    }

    /// The keys a run needs. They go to the computer in a file only its user can read, which the
    /// runner deletes as soon as it has read them; they are never put in a command, a log or the chat.
    static func secrets(app: AppModel, githubToken: String?, dataToken: String? = nil) -> VMSecrets {
        var connectorSecrets: [String: String] = [:]
        if let json = app.connectors.autonomousSecretsJSON(),
           let values = try? JSONDecoder().decode([String: String].self, from: Data(json.utf8)) {
            connectorSecrets = values
        }
        return VMSecrets(
            openRouterKey: app.openRouter.autonomousSecretKey,
            providers: app.openRouter.readyExternalProviders,
            githubToken: githubToken,
            dataToken: dataToken,
            connectors: app.connectors.computerRunConnectors(),
            connectorSecrets: connectorSecrets,
            githubApp: githubApp(app: app)
        )
    }

    /// MAIPA-G's GitHub App, so a run on the computer renews its own GitHub tokens instead of
    /// losing GitHub partway through a long reply while the phone is away. The same key Autonomous
    /// jobs already keep in their repos' Actions secrets; on the computer it stays in the runner's
    /// memory only.
    static func githubApp(app: AppModel) -> VMGitHubApp? {
        guard let credentials = app.github.credentials, let installation = app.github.installationID,
              !credentials.privateKeyPEM.isEmpty else { return nil }
        return VMGitHubApp(clientID: credentials.clientID, installationID: installation, privateKeyPEM: credentials.privateKeyPEM)
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
