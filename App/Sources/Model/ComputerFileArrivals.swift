import AgentCore
import Foundation

/// Files a reply on the computer made, on their way to this phone. Each comes over once at a time
/// in the background (a 150 MB .ipa takes a while, and the reply's state mustn't wait for it), and
/// one that fails says why on its card, with Retry. It used to fail silently and the card said
/// "Still coming from your computer…" for ever (the Korg chat, 14 November 2026).
@MainActor
@Observable
final class ComputerFileArrivals {
    private(set) var arriving: Set<UUID> = []
    private(set) var failures: [UUID: String] = [:]
    /// Where each file comes from, kept for Retry.
    @ObservationIgnored private var sources: [UUID: (result: GeneratedImageResult, runID: String, computer: ComputerControl?)] = [:]
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored weak var app: AppModel?

    func isArriving(_ id: UUID) -> Bool { arriving.contains(id) }
    func failure(for id: UUID) -> String? { failures[id] }
    func canRetry(_ id: UUID) -> Bool { sources[id] != nil && !arriving.contains(id) }

    /// Starts bringing every file in `results` that isn't already on its way. A file that failed
    /// waits for Retry rather than starting over with every new state.
    func bring(_ results: [GeneratedImageResult], runID: String, computer: ComputerControl?) {
        for result in results where sources[result.id] == nil || (failures[result.id] == nil && tasks[result.id] == nil) {
            sources[result.id] = (result, runID, computer)
            start(result.id)
        }
    }

    func retry(_ id: UUID) {
        guard sources[id] != nil, tasks[id] == nil else { return }
        failures[id] = nil
        start(id)
    }

    /// Waits for the files of `runID` that come over the computer's command tool (they need the
    /// run's folder). True when none of them failed, so the folder can go.
    func finishCommandTransfers(runID: String) async -> Bool {
        let waiting = sources.filter { $0.value.runID == runID && $0.value.result.relay == nil }.map(\.key)
        for id in waiting { await tasks[id]?.value }
        return !waiting.contains { failures[$0] != nil }
    }

    private func start(_ id: UUID) {
        guard let source = sources[id], tasks[id] == nil, let app else { return }
        let dataDirectory = app.paths.data
        let account = app.github
        arriving.insert(id)
        tasks[id] = Task { [weak self] in
            let github = account.client
            var problem: String?
            do {
                try await VMMedia.bring(source.result, runID: source.runID, computer: source.computer, github: github, into: dataDirectory)
            } catch {
                problem = ErrorExplainer.explain(error).message
            }
            guard let self else { return }
            self.arriving.remove(id)
            self.tasks[id] = nil
            if let problem {
                self.failures[id] = problem
                _ = self.app?.report(ToolInputError(problem), area: "computer files", operation: "bring \(source.result.attachment.name) from the computer", path: source.result.attachment.path)
            } else {
                self.failures[id] = nil
            }
        }
    }
}
