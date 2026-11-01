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
    private(set) var pendingPaths: [String] = []
    private(set) var fileProblems: [DataRepoSync.FileProblem] = []

    var isEverythingBackedUp: Bool {
        status == .idle && pendingPaths.isEmpty && fileProblems.isEmpty && lastSaved != nil
    }

    @ObservationIgnored weak var app: AppModel?
    @ObservationIgnored private var engine: DataRepoSync?
    @ObservationIgnored private var setup: (client: GitHubClient, owner: String, installationID: Int)?
    @ObservationIgnored private var scheduled: Task<Void, Never>?
    @ObservationIgnored private var activeSyncTask: Task<DataRepoSync.Report, Error>?
    @ObservationIgnored private var isRunning = false
    @ObservationIgnored private var runAgain = false
    private let paths: AppPaths

    private struct SyncTimeoutError: LocalizedError {
        var errorDescription: String? { "GitHub backup took too long and timed out. MAIPA-G will retry automatically." }
    }

    init(paths: AppPaths) {
        self.paths = paths
    }

    var repoURL: URL? { repo?.webURL }

    /// Sets saving up for a connected account and brings this phone up to date with GitHub.
    func configure(client: GitHubClient, owner: String, installationID: Int) async {
        engine = DataRepoSync(github: client, dataDirectory: paths.data, stateURL: paths.syncState)
        setup = (client, owner, installationID)
        repo = nil
        await syncNow()
    }

    /// Saves in a few seconds; more changes in the meantime wait for the same save.
    func request(after seconds: Double = 4.5) {
        guard engine != nil else { return }
        if pendingPaths.isEmpty { pendingPaths = ["Changes on this phone"] }
        scheduled?.cancel()
        let clampedDelay = max(0, seconds)
        scheduled = Task { [weak self] in
            if clampedDelay > 0 {
                do { try await Task.sleep(nanoseconds: UInt64(clampedDelay * 1_000_000_000)) }
                catch { return }
            }
            guard !Task.isCancelled else { return }
            await self?.runScheduledSync()
        }
    }

    private func runScheduledSync() async {
        // Clear the cancellable delay handle before syncing. Later edits may schedule another
        // save, but can no longer cancel a sync that is already uploading files.
        scheduled = nil
        await syncNow()
    }

    func syncNow() async {
        guard let engine, let setup else { return }
        if isRunning {
            runAgain = true
            return
        }
        isRunning = true
        defer {
            isRunning = false
            activeSyncTask = nil
        }
        var passes = 0
        repeat {
            runAgain = false
            passes += 1
            status = .saving
            do {
                let client = setup.client
                let owner = setup.owner
                let installationID = setup.installationID
                let needsRepoEnsure = (repo == nil)
                let worker = Task<DataRepoSync.Report, Error> {
                    if needsRepoEnsure {
                        _ = try await engine.ensureRepository(owner: owner) { repositoryID in
                            try await client.addRepositoryToInstallation(installationID: installationID, repositoryID: repositoryID)
                        }
                    }
                    return try await engine.sync()
                }
                activeSyncTask = worker
                let report = try await Self.awaitWithTimeout(seconds: 180, task: worker)
                activeSyncTask = nil
                if repo == nil {
                    repo = await engine.state.repo ?? RepoRef(owner: owner, name: DataRepoSync.repoName)
                }
                for problem in report.problems {
                    await app?.diagnostics.record(
                        error: ToolInputError(problem.message),
                        area: "saving",
                        operation: problem.stage.rawValue,
                        path: problem.path
                    )
                }
                fileProblems = report.problems
                pendingPaths = await engine.pendingPaths()
                lastSaved = Date()
                status = .idle
                if !report.downloaded.isEmpty || !report.deletedHere.isEmpty {
                    await app?.dataChangedFromGitHub(report)
                }
                if runAgain, passes >= 2 {
                    runAgain = false
                    request(after: 6)
                    return
                }
            } catch {
                activeSyncTask?.cancel()
                activeSyncTask = nil
                pendingPaths = await engine.pendingPaths()
                await app?.diagnostics.record(error: error, area: "saving", operation: "sync")
                if error is SyncTimeoutError {
                    status = lastSaved != nil ? .idle : .failed(Self.describe(error))
                    request(after: 20)
                } else {
                    status = .failed(Self.describe(error))
                }
                return
            }
        } while runAgain
    }

    private nonisolated static func awaitWithTimeout<T: Sendable>(
        seconds: Double,
        task: Task<T, Error>
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await task.value
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                task.cancel()
                throw SyncTimeoutError()
            }
            guard let first = try await group.next() else {
                task.cancel()
                throw SyncTimeoutError()
            }
            group.cancelAll()
            return first
        }
    }

    /// Screenshots only.
    func previewSaved() {
        status = .idle
        lastSaved = Date().addingTimeInterval(-90)
        repo = RepoRef(owner: "2c2bhdhw9z-cell", name: DataRepoSync.repoName)
    }

    func reset() async {
        scheduled?.cancel()
        activeSyncTask?.cancel()
        activeSyncTask = nil
        await engine?.reset()
        engine = nil
        setup = nil
        repo = nil
        pendingPaths = []
        fileProblems = []
        status = .off
    }

    static func describe(_ error: Error) -> String {
        if let error = error as? DataRepoSync.Failure {
            switch error {
            case .notSetUp: return "Saving isn't set up yet."
            case .repoNotVisible: return "MAIPA-G can't see your MAIPA-G-data repo. Let MAIPA-G into it on GitHub (Settings, Choose which repos MAIPA-G can use)."
            }
        }
        if let error = error as? GitHubAPIError {
            if error.isRateLimited { return "GitHub's hourly limit was reached. Saving will try again later." }
            return "GitHub said: \(error.message)"
        }
        if let error = error as? HTTPError, error.isOffline { return "Offline. Your chats are safe on the phone and will be saved when you're back online." }
        if case GitHubAppSession.Failure.userSignInExpired = error { return "Your GitHub sign-in ran out. Sign in again in Settings." }
        if case GitHubAppSession.Failure.noUserToken = error { return "MAIPA-G needs you to sign in to GitHub once more to make your MAIPA-G-data repo. Tap Sign in to GitHub again in Settings." }
        return ErrorExplainer.explain(error).message
    }
}
