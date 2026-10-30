import AgentCore
import Foundation
import Observation

@MainActor
@Observable
final class MemoryLibrary {
    private(set) var memories: [MemoryRecord] = []
    private(set) var isLoaded = false
    private(set) var lastError: String?

    @ObservationIgnored weak var app: AppModel?
    @ObservationIgnored let store: ProductStore<MemoryRecord>

    init(dataDirectory: URL) {
        store = ProductStore(dataDirectory: dataDirectory, folder: "memories")
    }

    var activeTexts: [String] {
        guard app?.settings.memoriesOn != false else { return [] }
        return memories.filter(\.isEnabled).map { "\($0.id.uuidString.lowercased()): \($0.text)" }
    }

    func load() async {
        guard !PreviewScenes.isActive else { return }
        memories = await store.loadAll()
        isLoaded = true
    }

    func preview(_ values: [MemoryRecord]) {
        memories = values
        isLoaded = true
    }

    @discardableResult
    func save(_ value: MemoryRecord) async -> MemoryRecord? {
        var record = value
        let clean = record.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { lastError = "Memory text can't be empty."; return nil }
        record.text = clean
        record.format = MemoryRecord.currentFormat
        record.updatedAt = Date()
        do {
            try await store.save(record)
            await load()
            app?.sync.request()
            return record
        } catch {
            lastError = ErrorExplainer.explain(error).message
            return nil
        }
    }

    func add(_ text: String) async -> MemoryRecord? {
        await save(MemoryRecord(text: text, source: .user))
    }

    func setEnabled(_ id: UUID, _ enabled: Bool) async {
        guard var record = memories.first(where: { $0.id == id }) else { return }
        record.isEnabled = enabled
        _ = await save(record)
    }

    func delete(_ id: UUID) async {
        guard let record = memories.first(where: { $0.id == id }) else { return }
        do {
            try await app?.trash.move(id: id, kind: .memory, title: String(record.text.prefix(80)), originalPath: await store.relativePath(for: id))
            await load()
            app?.sync.request()
        } catch { lastError = ErrorExplainer.explain(error).message }
    }

    /// Returns the new memory id, or nil when the tap removed an existing star.
    func toggleStar(messageID: UUID, text: String, currentMemoryID: UUID?) async -> UUID? {
        guard let trash = app?.trash else {
            lastError = "The star couldn't change because the app's storage isn't ready. Open the chat again and retry."
            return currentMemoryID
        }
        do {
            let result = try await StarMemoryService.toggle(store: store, trash: trash, messageID: messageID, text: text, currentMemoryID: currentMemoryID)
            await load()
            app?.sync.request()
            return result
        } catch {
            lastError = ErrorExplainer.explain(error).message
            return currentMemoryID
        }
    }
}
