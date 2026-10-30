import Foundation

public actor BackgroundCommandRegistry {
    public static let shared = BackgroundCommandRegistry()

    private struct Entry {
        var task: Task<ToolOutput, Error>
        var result: Result<ToolOutput, Error>?
    }
    private var entries: [String: Entry] = [:]

    public func start(_ operation: @escaping @Sendable () async throws -> ToolOutput) -> String {
        let id = UUID().uuidString.lowercased()
        let task = Task { try await operation() }
        entries[id] = Entry(task: task, result: nil)
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
            return ToolOutput(forModel: "Background command \(id) failed: \(ErrorExplainer.explain(error).message)", summary: "Background command failed", isError: true)
        }
    }

    public func stop(_ id: String) -> ToolOutput {
        guard let entry = entries[id] else {
            return ToolOutput(forModel: "There is no background command \(id).", summary: "Background command not found", isError: true)
        }
        entry.task.cancel()
        return ToolOutput(forModel: "Stopped background command \(id) and its process tree.", summary: "Stopped background command")
    }

    private func finish(_ id: String, result: Result<ToolOutput, Error>) {
        guard var entry = entries[id] else { return }
        entry.result = result
        entries[id] = entry
    }
}
