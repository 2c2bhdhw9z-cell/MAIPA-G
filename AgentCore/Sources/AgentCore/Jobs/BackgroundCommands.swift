import Foundation

public actor BackgroundCommandRegistry {
    public static let shared = BackgroundCommandRegistry()
    public static let maxConcurrentCommands = 8
    private static let maxRetainedFinishedEntries = 32

    private struct Entry {
        var task: Task<ToolOutput, Error>?
        var result: Result<ToolOutput, Error>?
        var startedAt: Date
    }
    private var entries: [String: Entry] = [:]
    private var insertionOrder: [String] = []

    public func start(_ operation: @escaping @Sendable () async throws -> ToolOutput) throws -> String {
        let runningCount = entries.values.filter { $0.result == nil }.count
        if runningCount >= Self.maxConcurrentCommands {
            throw ToolInputError("Already running \(runningCount) background commands. Wait for one to finish or stop one before starting more.")
        }
        let id = UUID().uuidString.lowercased()
        let task = Task { try await operation() }
        entries[id] = Entry(task: task, result: nil, startedAt: Date())
        insertionOrder.append(id)
        pruneFinishedIfNeeded()
        Task { [weak self] in
            let result: Result<ToolOutput, Error>
            do { result = .success(try await task.value) }
            catch { result = .failure(error) }
            await self?.finish(id, result: result)
        }
        return id
    }

    public func status(_ id: String) -> ToolOutput {
        guard let entry = entries[id] else {
            return ToolOutput(forModel: "There is no background command \(id).", summary: "Background command not found", isError: true)
        }
        switch entry.result {
        case nil:
            return ToolOutput(forModel: "Background command \(id) is still running.", summary: "Background command running")
        case .success(let output):
            return ToolOutput(forModel: "Background command \(id) finished.\n\(output.forModel)", summary: output.summary, detail: output.detail, isError: output.isError)
        case .failure(let error):
            if error is CancellationError {
                return ToolOutput(forModel: "Background command \(id) was stopped.", summary: "Background command stopped", isError: false)
            }
            return ToolOutput(forModel: "Background command \(id) failed: \(ErrorExplainer.explain(error).message)", summary: "Background command failed", isError: true)
        }
    }

    public func stop(_ id: String) -> ToolOutput {
        guard var entry = entries[id] else {
            return ToolOutput(forModel: "There is no background command \(id).", summary: "Background command not found", isError: true)
        }
        entry.task?.cancel()
        entry.task = nil
        if entry.result == nil {
            entry.result = .failure(CancellationError())
        }
        entries[id] = entry
        return ToolOutput(forModel: "Stopped background command \(id) and its process tree.", summary: "Stopped background command")
    }

    public func stopAll() {
        for id in Array(entries.keys) {
            if var entry = entries[id], entry.result == nil {
                entry.task?.cancel()
                entry.task = nil
                entry.result = .failure(CancellationError())
                entries[id] = entry
            }
        }
    }

    private func finish(_ id: String, result: Result<ToolOutput, Error>) {
        guard var entry = entries[id] else { return }
        entry.task = nil
        if entry.result == nil {
            entry.result = result
        }
        entries[id] = entry
        pruneFinishedIfNeeded()
    }

    private func pruneFinishedIfNeeded() {
        let finishedIDs = insertionOrder.filter { entries[$0]?.result != nil }
        guard finishedIDs.count > Self.maxRetainedFinishedEntries else { return }
        let excess = finishedIDs.count - Self.maxRetainedFinishedEntries
        for oldID in finishedIDs.prefix(excess) {
            entries.removeValue(forKey: oldID)
            insertionOrder.removeAll { $0 == oldID }
        }
    }
}
