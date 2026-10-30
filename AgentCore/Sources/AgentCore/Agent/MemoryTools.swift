import Foundation

public enum StarMemoryService {
    /// Creates one memory per message, or moves it to Recently deleted when the same star is tapped
    /// again. Un-starring never erases the memory: it stays restorable for 30 days.
    public static func toggle(store: ProductStore<MemoryRecord>, trash: TrashStore, messageID: UUID, text: String, currentMemoryID: UUID?) async throws -> UUID? {
        let existing: MemoryRecord?
        if let currentMemoryID, let current = await store.load(currentMemoryID) {
            existing = current
        } else {
            existing = await store.loadAll().first(where: { $0.sourceMessageID == messageID })
        }
        if let existing {
            try await trash.move(id: existing.id, kind: .memory, title: String(existing.text.prefix(80)), originalPath: await store.relativePath(for: existing.id))
            return nil
        }
        if currentMemoryID != nil { return nil }
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw ToolInputError("Memory text can't be empty.") }
        let record = MemoryRecord(text: clean, source: .star, sourceMessageID: messageID)
        try await store.save(record)
        return record.id
    }
}

/// AI-facing memory operations use the same durable store as the Memories screen.
public struct AddMemoryTool: AgentTool {
    public let store: ProductStore<MemoryRecord>
    public let name = "add_memory"

    public init(store: ProductStore<MemoryRecord>) { self.store = store }

    public var spec: ToolSpec {
        ToolSpec(name: name, description: "Save a useful fact or preference for future new chats. Do not save temporary task details.", parameters: [
            "type": "object",
            "properties": ["text": ["type": "string", "description": "The concise fact or preference to remember."]],
            "required": ["text"],
        ])
    }

    public func runningSummary(for arguments: JSONValue) -> String { "Saving a memory…" }

    public func run(arguments: JSONValue, progress: @escaping @Sendable (String) -> Void) async throws -> ToolOutput {
        let text = try arguments.requiredString("text").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ToolInputError("Memory text can't be empty.") }
        if let existing = await store.loadAll().first(where: { $0.text.localizedCaseInsensitiveCompare(text) == .orderedSame }) {
            return ToolOutput(forModel: "That memory already exists (id: \(existing.id.uuidString)).", summary: "Memory already saved", detail: existing.text)
        }
        let record = MemoryRecord(text: text, source: .ai)
        try await store.save(record)
        return ToolOutput(forModel: "Saved memory \(record.id.uuidString): \(text)", summary: "Saved a memory", detail: text)
    }
}

public struct EditMemoryTool: AgentTool {
    public let store: ProductStore<MemoryRecord>
    public let name = "edit_memory"

    public init(store: ProductStore<MemoryRecord>) { self.store = store }

    public var spec: ToolSpec {
        ToolSpec(name: name, description: "Edit one existing memory when it is outdated or needs correction.", parameters: [
            "type": "object",
            "properties": [
                "id": ["type": "string", "description": "The memory UUID."],
                "text": ["type": "string", "description": "The complete corrected memory."],
                "enabled": ["type": "boolean", "description": "Whether to use this memory in new chats."],
            ],
            "required": ["id", "text"],
        ])
    }

    public func runningSummary(for arguments: JSONValue) -> String { "Updating a memory…" }

    public func run(arguments: JSONValue, progress: @escaping @Sendable (String) -> Void) async throws -> ToolOutput {
        guard let id = UUID(uuidString: try arguments.requiredString("id")), var record = await store.load(id) else {
            throw ToolInputError("There is no memory with that id.")
        }
        let text = try arguments.requiredString("text").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ToolInputError("Memory text can't be empty.") }
        record.text = text
        if let enabled = arguments.optionalBool("enabled") { record.isEnabled = enabled }
        record.source = .ai
        record.updatedAt = Date()
        try await store.save(record)
        return ToolOutput(forModel: "Updated memory \(record.id.uuidString): \(text)", summary: "Updated a memory", detail: text)
    }
}
