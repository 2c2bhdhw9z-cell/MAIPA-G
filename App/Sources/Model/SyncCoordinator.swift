import AgentCore
import Foundation
import Observation
import UIKit

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
    /// More about the current state when there is more to say, in plain English: why saving
    /// paused, how many files are left, and that it carries on by itself. Nil when all is well.
    private(set) var detail: String?

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
    /// Finishes when the passes running now are done, for a caller that must wait for them.
    @ObservationIgnored private var runningPasses: Task<Void, Never>?
    /// A change was asked to be saved while a pass was running, so that pass's list of what is
    /// still unsaved may already be out of date.
    @ObservationIgnored private var changedDuringPass = false
    /// When the first request in the current burst arrived. Repeated saves during a long turn
    /// must not push the backup out forever, so the delay is clamped against this.
    @ObservationIgnored private var burstStartedAt: Date?
    private let paths: AppPaths

    /// A pass that heard nothing from GitHub (no answer, no bytes sent) for `quietLimit`.
    private struct SyncTimeoutError: LocalizedError {
        var filesLeft: Int?
        var errorDescription: String? { SyncCoordinator.pausedText(filesLeft: filesLeft) }
    }

    /// A save that makes no progress for this long is stopped and tried again. It counts from the
    /// last answer from GitHub or the last bytes sent, not from the start, so a big backlog that
    /// keeps moving is never cut off.
    nonisolated static let quietLimit: TimeInterval = 180
    /// In the background a pass stops starting uploads this long before iOS's time runs out, so it
    /// can commit what it sent and end cleanly instead of being frozen part way through.
    nonisolated static let backgroundMargin: TimeInterval = 10
    /// The longest a pass keeps starting uploads once the app is in the background.
    nonisolated static let backgroundPassSeconds: TimeInterval = 18

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

    /// The app is in front again. Time spent suspended isn't a stuck save, so the watchdog counts
    /// afresh, and a pass no longer has to hurry to finish before iOS freezes the app.
    func appBecameActive() {
        engine?.activity.touch()
        engine?.monitor.clearFinish()
    }

    /// Saves in a few seconds; more changes in the meantime wait for the same save.
    func request(after seconds: Double = 4.5) {
        guard engine != nil else { return }
        if isRunning { changedDuringPass = true }
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

    /// In the background, asks passes to stop starting uploads in good time before iOS's time runs
    /// out. Returns false when there is too little time left to start one at all.
    @discardableResult
    private func finishBeforeSuspension(_ engine: DataRepoSync) -> Bool {
        let remaining = UIApplication.shared.backgroundTimeRemaining
        // A huge value means iOS set no limit (the app is still active, or a background task).
        let seconds = remaining < 10_000 ? min(remaining - Self.backgroundMargin, Self.backgroundPassSeconds) : Self.backgroundPassSeconds
        engine.monitor.finish(within: max(seconds, 0))
        return seconds > 0
    }

    func syncNow() async {
        guard let engine, let setup else { return }
        let inBackground = UIApplication.shared.applicationState == .background
        if isRunning {
            runAgain = true
            if inBackground {
                // iOS is about to freeze the app: the running pass wraps up in the time left, and
                // this caller (who holds the background time) waits until it has.
                finishBeforeSuspension(engine)
                await runningPasses?.value
            }
            return
        }
        if inBackground {
            guard finishBeforeSuspension(engine) else { return }
        } else {
            engine.monitor.clearFinish()
        }
        isRunning = true
        let (finished, finish) = AsyncStream<Void>.makeStream()
        runningPasses = Task { for await _ in finished {} }
        defer {
            isRunning = false
            activeSyncTask = nil
            finish.finish()
            runningPasses = nil
        }
        var passes = 0
        repeat {
            runAgain = false
            changedDuringPass = false
            passes += 1
            status = .saving
            let committedBefore = engine.monitor.committedFiles
            do {
                let client = setup.client
                let owner = setup.owner
                let installationID = setup.installationID
                let needsRepoEnsure = (repo == nil)
                // A chat whose reply is still streaming is saved once its reply ends.
                let held = app?.library.streamingChatPaths ?? []
                let worker = Task<DataRepoSync.Report, Error> {
                    if needsRepoEnsure {
                        _ = try await engine.ensureRepository(owner: owner) { repositoryID in
                            try await client.addRepositoryToInstallation(installationID: installationID, repositoryID: repositoryID)
                        }
                    }
                    return try await engine.sync(holding: held)
                }
                activeSyncTask = worker
                let report: DataRepoSync.Report
                do {
                    report = try await AgentLoop.bounded(seconds: Self.quietLimit, label: "GitHub backup", activity: engine.activity) {
                        try await worker.value
                    }
                } catch is ToolTimedOut {
                    worker.cancel()
                    throw SyncTimeoutError(filesLeft: engine.monitor.filesLeft)
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
                if report.remoteListingIncomplete {
                    await app?.diagnostics.record(
                        error: ToolInputError("GitHub's list of saved files was too long to read in full, so nothing was deleted on either side this time."),
                        area: "saving",
                        operation: "list"
                    )
                }
                fileProblems = report.problems
                // The pass worked this out from the files it had already read. A change asked for
                // while it ran may not be in it, and is saved by the pass that request starts.
                pendingPaths = changedDuringPass && report.pendingPaths.isEmpty ? ["Changes on this phone"] : report.pendingPaths
                lastSaved = Date()
                if !report.downloaded.isEmpty || !report.deletedHere.isEmpty {
                    await app?.dataChangedFromGitHub(report)
                }
                if let until = report.rateLimitedUntil {
                    // GitHub asked for a pause. What went up is committed and kept; the rest waits
                    // until GitHub's time, then carries on. Not logged: nothing failed.
                    let text = Self.rateLimitText(until: until, filesLeft: report.deferred.count)
                    detail = text
                    status = .failed(text)
                    retryAfterLimit(seconds: Self.pauseSeconds(until: until))
                    return
                }
                detail = nil
                status = .idle
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
                if let timeout = error as? SyncTimeoutError {
                    // GitHub went quiet. If this pass committed anything first it is still saving,
                    // only paused, and that isn't an error worth logging every time.
                    let madeProgress = engine.monitor.committedFiles > committedBefore
                    let text = Self.pausedText(filesLeft: timeout.filesLeft)
                    detail = text
                    if madeProgress {
                        status = .saving
                    } else {
                        await app?.diagnostics.record(error: error, area: "saving", operation: "sync")
                        status = .failed(text)
                    }
                    request(after: 20)
                } else if let wait = Self.rateLimitRetryDelay(error) {
                    // GitHub stops answering for the rest of the hour. Trying again before then
                    // only uses up the next hour too, so wait for the reset; this used to say it
                    // would try again but never did.
                    await app?.diagnostics.record(error: error, area: "saving", operation: "sync")
                    let text = Self.describe(error)
                    detail = text
                    status = .failed(text)
                    retryAfterLimit(seconds: wait)
                } else {
                    await app?.diagnostics.record(error: error, area: "saving", operation: "sync")
                    detail = nil
                    status = .failed(Self.describe(error))
                }
                return
            }
        } while runAgain
    }

    /// What the status says when GitHub went quiet in the middle of a save.
    nonisolated static func pausedText(filesLeft: Int?) -> String {
        let left: String
        switch filesLeft {
        case .some(1): left = "1 file is still to save. "
        case .some(let count) where count > 1: left = "\(count) files are still to save. "
        default: left = ""
        }
        return "Saving paused: GitHub stopped answering for a few minutes. \(left)Nothing is lost, and saving carries on by itself."
    }

    /// What the status says while GitHub has asked MAIPA-G to wait.
    nonisolated static func rateLimitText(until: Date, filesLeft: Int) -> String {
        let left = filesLeft == 1 ? "1 file waits" : filesLeft > 1 ? "\(filesLeft) files wait" : "The rest waits"
        let time = until.formatted(date: .omitted, time: .shortened)
        return "GitHub asked MAIPA-G to slow down. What was saved is kept. \(left) until about \(time), then saving carries on by itself."
    }

    /// Seconds to wait for a pause GitHub asked for: its own time (a few seconds' allowance), or
    /// ten minutes when it gave none; never more than an hour.
    nonisolated static func pauseSeconds(until: Date?, now: Date = Date()) -> Double {
        guard let until else { return 600 }
        return min(max(until.timeIntervalSince(now) + 3, 5), 3600)
    }

    /// Seconds until GitHub says to try again (its `retry-after`, or the hourly reset), or nil when
    /// `error` isn't a rate limit.
    nonisolated static func rateLimitRetryDelay(_ error: Error, now: Date = Date()) -> Double? {
        guard let error = error as? GitHubAPIError, error.isRateLimited else { return nil }
        return pauseSeconds(until: error.retryAt ?? error.rateLimitResetsAt, now: now)
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
        detail = nil
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
            if error.isRateLimited {
                if let until = error.retryAt ?? error.rateLimitResetsAt {
                    return "GitHub asked MAIPA-G to wait until about \(until.formatted(date: .omitted, time: .shortened)). Saving carries on by itself then."
                }
                return "GitHub's hourly limit was reached. Saving will try again later."
            }
            return "GitHub said: \(error.message)"
        }
        if let error = error as? HTTPError, error.isOffline { return "Offline. Your chats are safe on the phone and will be saved when you're back online." }
        if case GitHubAppSession.Failure.userSignInExpired = error { return "Your GitHub sign-in ran out. Sign in again in Settings." }
        if case GitHubAppSession.Failure.noUserToken = error { return "MAIPA-G needs you to sign in to GitHub once more to make your MAIPA-G-data repo. Tap Sign in to GitHub again in Settings." }
        return ErrorExplainer.explain(error).message
    }
}
