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
    /// When the first request in the current burst arrived. Repeated saves during a long turn
    /// must not push the backup out forever, so the delay is clamped against this.
    @ObservationIgnored private var burstStartedAt: Date?
    private let paths: AppPaths

    private struct SyncTimeoutError: LocalizedError {
        var errorDescription: String? { "GitHub backup took too long and timed out. MAIPA-G will retry automatically." }
    }

    /// A save that makes no progress for this long is stopped and tried again. It counts from the
    /// last file sent, not from the start, so a big backlog that keeps moving is never cut off.
    nonisolated static let quietLimit: TimeInterval = 180

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
        let now = Date()
        if burstStartedAt == nil { burstStartedAt = now }
        // Hard ceiling: however many saves arrive during a long turn, the backup still runs.
        let maxWait: TimeInterval = 30
        let elapsed = now.timeIntervalSince(burstStartedAt ?? now)
        let delay = min(max(0, seconds), max(0, maxWait - elapsed))
        scheduled?.cancel()
        scheduled = Task { [weak self] in
            if delay > 0 {
                do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
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
        burstStartedAt = nil
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
                let report: DataRepoSync.Report
                do {
                    report = try await AgentLoop.bounded(seconds: Self.quietLimit, label: "GitHub backup", activity: engine.activity) {
                        try await worker.value
                    }
                } catch is ToolTimedOut {
                    worker.cancel()
                    throw SyncTimeoutError()
                }
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
                if report.hasMoreToSave {
                    // This pass saved what it could in one go; the rest follows straight away.
                    runAgain = false
                    request(after: 1)
                    return
                }
                if runAgain, passes >= 2 {
                    runAgain = false
                    request(after: 6)
                    return
                }
            } catch {
                activeSyncTask?.cancel()
                activeSyncTask = nil
                // Do not re-read every saved file here. That scan loaded the whole library into
                // memory while the screen still said "Saving…", and iOS closed the app for it.
                await app?.diagnostics.record(error: error, area: "saving", operation: "sync")
                if error is SyncTimeoutError {
                    status = lastSaved != nil ? .idle : .failed(Self.describe(error))
                    request(after: 20)
                } else if let wait = Self.rateLimitRetryDelay(error) {
                    // GitHub stops answering for the rest of the hour. Trying again before then
                    // only uses up the next hour too, so wait for the reset; this used to say it
                    // would try again but never did.
                    status = .failed(Self.describe(error))
                    retryAfterLimit(seconds: wait)
                } else {
                    status = .failed(Self.describe(error))
                }
                return
            }
        } while runAgain
    }

    /// Seconds until GitHub's hourly limit resets (at least a minute, at most an hour), or nil
    /// when `error` isn't that limit.
    nonisolated static func rateLimitRetryDelay(_ error: Error, now: Date = Date()) -> Double? {
        guard let error = error as? GitHubAPIError, error.isRateLimited else { return nil }
        let wait = error.rateLimitResetsAt.map { $0.timeIntervalSince(now) + 5 } ?? 600
        return min(max(wait, 60), 3600)
    }

    /// `request(after:)` caps its wait at 30 seconds so edits are saved quickly; a wait for the
    /// hourly limit has to be longer, so it is scheduled here instead.
    private func retryAfterLimit(seconds: Double) {
        scheduled?.cancel()
        burstStartedAt = nil
        scheduled = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) } catch { return }
            guard !Task.isCancelled else { return }
            await self?.runScheduledSync()
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
