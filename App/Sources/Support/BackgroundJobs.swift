import AgentCore
import BackgroundTasks
import Foundation
import Observation

@MainActor
@Observable
final class BackgroundJobs {
    static let refreshIdentifier = "dev.maipag.app.refresh"
    static let continuedIdentifier = "dev.maipag.app.autonomous"

    weak var app: AppModel?
    private(set) var lastFailure: String?
    private var registered = false

    func register() {
        guard !registered, !PreviewScenes.isActive else { return }
        registered = true
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.refreshIdentifier, using: nil) { [weak self] task in
            guard let refresh = task as? BGAppRefreshTask else { return }
            let work = Task { @MainActor [weak self] in
                await self?.app?.jobs.refresh()
                refresh.setTaskCompleted(success: !Task.isCancelled)
            }
            refresh.expirationHandler = { [weak self] in
                work.cancel()
                Task { @MainActor in
                    self?.lastFailure = "iOS ended MAIPA-G’s background refresh before job status finished updating. The GitHub job keeps running; open Jobs to refresh it."
                }
            }
        }
        if #available(iOS 26.0, *) {
            BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.continuedIdentifier, using: nil) { [weak self] task in
                guard let continued = task as? BGContinuedProcessingTask else { return }
                let work = Task { @MainActor [weak self] in
                    continued.progress.totalUnitCount = 100
                    var ticks: Int64 = 0
                    while !Task.isCancelled, let self, self.app?.jobs.activeCount ?? 0 > 0 {
                        await self.app?.jobs.refresh()
                        ticks = min(ticks + 1, 99)
                        continued.progress.completedUnitCount = ticks
                        continued.updateTitle("MAIPA-G is working", subtitle: "Checking Autonomous jobs")
                        try? await Task.sleep(nanoseconds: 20_000_000_000)
                    }
                    continued.progress.completedUnitCount = 100
                    continued.setTaskCompleted(success: !Task.isCancelled)
                }
                continued.expirationHandler = { [weak self] in
                    work.cancel()
                    Task { @MainActor in
                        let title = self?.app?.jobs.jobs.first(where: { ![.done, .failed, .stopped].contains($0.status) })?.title ?? "the active job"
                        self?.lastFailure = "iOS stopped background monitoring for \(title). The GitHub job itself keeps running; open Jobs to see its result."
                    }
                }
            }
        }
    }

    func schedule(hasActiveJobs: Bool) {
        guard !PreviewScenes.isActive else { return }
        let refresh = BGAppRefreshTaskRequest(identifier: Self.refreshIdentifier)
        refresh.earliestBeginDate = Date().addingTimeInterval(hasActiveJobs ? 15 * 60 : 60 * 60)
        do {
            try BGTaskScheduler.shared.submit(refresh)
        } catch {
            lastFailure = "Background refresh could not be scheduled: \(ErrorExplainer.explain(error).message)"
        }

        if #available(iOS 26.0, *), hasActiveJobs {
            let request = BGContinuedProcessingTaskRequest(
                identifier: Self.continuedIdentifier,
                title: "MAIPA-G is working",
                subtitle: "Watching Autonomous jobs"
            )
            request.strategy = .queue
            do {
                try BGTaskScheduler.shared.submit(request)
            } catch {
                lastFailure = "Background job monitoring could not be scheduled: \(ErrorExplainer.explain(error).message)"
            }
        }
    }
}
