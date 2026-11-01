import AgentCore
import BackgroundTasks
import Foundation
import Observation

/// Wraps Objective-C `BGTask` subclasses that predate `Sendable` annotations so `nonisolated`
/// system callbacks can hop to `@MainActor` cleanly under Swift 6 strict concurrency without
/// inheriting `@MainActor` isolation from `BackgroundJobs`.
private struct BGTaskBox<T>: @unchecked Sendable {
    let value: T
}

@MainActor
@Observable
final class BackgroundJobs {
    nonisolated static let refreshIdentifier = "dev.maipag.app.refresh"
    nonisolated static let continuedIdentifier = "dev.maipag.app.autonomous"

    weak var app: AppModel?
    private(set) var lastFailure: String?
    /// True while iOS 26's `BGContinuedProcessingTask` is actively granting extended background execution
    /// so `BackgroundGrace`'s ~25s timer does not prematurely cancel active chats or sub-agents.
    private(set) var isContinuedProcessingActive = false
    private var registered = false

    func register() {
        guard !registered, !PreviewScenes.isActive else { return }
        registered = true
        Self.registerSystemTasks(owner: self)
    }

    /// Registers `BGTaskScheduler` callbacks from a `nonisolated` context so Swift 6 never injects
    /// a `@MainActor` dispatch assertion into BackgroundTasks' background XPC launch or expiration queues.
    nonisolated private static func registerSystemTasks(owner: BackgroundJobs) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.refreshIdentifier, using: DispatchQueue.main) { [weak owner] task in
            guard let refresh = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            let box = BGTaskBox(value: refresh)
            let work = Task { @MainActor [weak owner] in
                await owner?.app?.jobs.refresh()
                box.value.setTaskCompleted(success: !Task.isCancelled)
            }
            refresh.expirationHandler = { [weak owner] in
                work.cancel()
                Task { @MainActor [weak owner] in
                    owner?.lastFailure = "iOS ended MAIPA-G’s background refresh before job status finished updating. The GitHub job keeps running; open Jobs to refresh it."
                }
            }
        }
        if #available(iOS 26.0, *) {
            BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.continuedIdentifier, using: DispatchQueue.main) { [weak owner] task in
                guard let continued = task as? BGContinuedProcessingTask else {
                    task.setTaskCompleted(success: false)
                    return
                }
                let box = BGTaskBox(value: continued)
                let work = Task { @MainActor [weak owner] in
                    owner?.isContinuedProcessingActive = true
                    defer { owner?.isContinuedProcessingActive = false }
                    box.value.progress.totalUnitCount = 100
                    var ticks: Int64 = 0
                    while !Task.isCancelled,
                          let owner,
                          let app = owner.app,
                          (app.jobs.activeCount > 0 || app.library.hasActiveWork) {
                        if app.jobs.activeCount > 0 {
                            await app.jobs.refresh()
                        }
                        ticks = min(ticks + 1, 99)
                        box.value.progress.completedUnitCount = ticks
                        let subtitle = app.library.activeWorkSummary ?? "Checking Autonomous jobs"
                        box.value.updateTitle("MAIPA-G is working", subtitle: subtitle)
                        try? await Task.sleep(nanoseconds: 4_000_000_000)
                    }
                    box.value.progress.completedUnitCount = 100
                    box.value.setTaskCompleted(success: !Task.isCancelled)
                }
                continued.expirationHandler = { [weak owner] in
                    work.cancel()
                    Task { @MainActor [weak owner] in
                        guard let owner else { return }
                        owner.isContinuedProcessingActive = false
                        owner.app?.library.suspendAllForBackground()
                        if (owner.app?.jobs.activeCount ?? 0) > 0 {
                            let title = owner.app?.jobs.jobs.first(where: { ![.done, .failed, .stopped].contains($0.status) })?.title ?? "the active job"
                            owner.lastFailure = "iOS stopped background monitoring for \(title). The GitHub job itself keeps running; open Jobs to see its result."
                        }
                    }
                }
            }
        }
    }

    func schedule(hasActiveJobs: Bool, hasActiveChats: Bool = false, chatSubtitle: String? = nil) {
        guard !PreviewScenes.isActive else { return }
        let anyActive = hasActiveJobs || hasActiveChats
        let refresh = BGAppRefreshTaskRequest(identifier: Self.refreshIdentifier)
        refresh.earliestBeginDate = Date().addingTimeInterval(anyActive ? 15 * 60 : 60 * 60)
        do {
            try BGTaskScheduler.shared.submit(refresh)
        } catch {
            lastFailure = "Background refresh could not be scheduled: \(ErrorExplainer.explain(error).message)"
        }

        if #available(iOS 26.0, *), anyActive {
            let subtitle = chatSubtitle ?? (hasActiveChats ? "Finishing active chat & sub-agents" : "Watching Autonomous jobs")
            let request = BGContinuedProcessingTaskRequest(
                identifier: Self.continuedIdentifier,
                title: "MAIPA-G is working",
                subtitle: subtitle
            )
            request.strategy = .queue
            do {
                try BGTaskScheduler.shared.submit(request)
            } catch {
                // Non-fatal if an identical request is already queued or running.
            }
        }
    }
}
