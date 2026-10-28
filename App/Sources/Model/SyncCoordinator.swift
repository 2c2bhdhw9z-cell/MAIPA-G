import AgentCore
import Foundation
import Observation

/// Keeps the chats and settings in the user's private MAIPA-G-data repo, a few seconds after each
/// change, when the app goes to the background, and when it comes back.
@MainActor
@Observable
final class SyncCoordinator {
    enum Status: Equatable {
        /// GitHub isn't connected, so nothing is saved there.
        case off
        case idle
        case saving
        case failed(String)
    }

    private(set) var status: Status = .off
    private(set) var lastSaved: Date?
    private(set) var repo: RepoRef?

    @ObservationIgnored weak var app: AppModel?
    @ObservationIgnored private var engine: DataRepoSync?
    @ObservationIgnored private var scheduled: Task<Void, Never>?
    @ObservationIgnored private var isRunning = false
    @ObservationIgnored private var runAgain = false
    private let paths: AppPaths

    init(paths: AppPaths) {
        self.paths = paths
    }

    var repoURL: URL? { repo?.webURL }

    /// Finds (or makes) MAIPA-G-data and brings this phone up to date with it.
    func configure(client: GitHubClient, owner: String, installationID: Int) async {
        let engine = DataRepoSync(github: client, dataDirectory: paths.data, stateURL: paths.syncState)
        self.engine = engine
        status = .saving
        do {
            repo = try await engine.ensureRepository(owner: owner) { repositoryID in
                try await client.addRepositoryToInstallation(installationID: installationID, repositoryID: repositoryID)
            }
            status = .idle
            await syncNow()
        } catch {
            status = .failed(Self.describe(error))
        }
    }

    /// Saves in a few seconds; more changes in the meantime wait for the same save.
    func request(after seconds: Double = 4) {
        guard engine != nil else { return }
        scheduled?.cancel()
        scheduled = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.syncNow()
        }
    }

    func syncNow() async {
        guard let engine else { return }
        if isRunning {
            runAgain = true
            return
        }
        isRunning = true
        defer { isRunning = false }
        repeat {
            runAgain = false
            status = .saving
            do {
                let report = try await engine.sync()
                lastSaved = Date()
                status = .idle
                if !report.downloaded.isEmpty || !report.deletedHere.isEmpty {
                    await app?.dataChangedFromGitHub(report)
                }
            } catch {
                status = .failed(Self.describe(error))
                return
            }
        } while runAgain
    }

    func reset() async {
        scheduled?.cancel()
        await engine?.reset()
        engine = nil
        repo = nil
        status = .off
    }

    static func describe(_ error: Error) -> String {
        if let error = error as? DataRepoSync.Failure {
            switch error {
            case .notSetUp: return "Saving isn't set up yet."
            case .repoNotVisible: return "MAIPA-G can't see your MAIPA-G-data repo. Let MAIPA-G into it on GitHub (Settings, GitHub, Choose repos)."
            }
        }
        if let error = error as? GitHubAPIError {
            if error.isRateLimited { return "GitHub's hourly limit was reached. Saving will try again later." }
            return "GitHub said: \(error.message)"
        }
        if let error = error as? HTTPError, error.isOffline { return "Offline. Your chats are safe on the phone and will be saved when you're back online." }
        if case GitHubAppSession.Failure.userSignInExpired = error { return "Your GitHub sign-in ran out. Sign in again in Settings." }
        return "Couldn't save to GitHub just now. It'll try again."
    }
}
