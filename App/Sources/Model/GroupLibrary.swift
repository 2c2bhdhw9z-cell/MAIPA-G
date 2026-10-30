import AgentCore
import Foundation
import Observation

@MainActor
@Observable
final class GroupLibrary {
    private(set) var groups: [ChatGroupRecord] = []
    private(set) var lastError: String?

    @ObservationIgnored weak var app: AppModel?
    @ObservationIgnored private let store: ProductStore<ChatGroupRecord>

    init(dataDirectory: URL) {
        store = ProductStore(dataDirectory: dataDirectory, folder: "groups")
    }

    func load() async {
        groups = await store.loadAll().sorted { $0.order == $1.order ? $0.createdAt < $1.createdAt : $0.order < $1.order }
    }

    func preview(_ values: [ChatGroupRecord]) { groups = values.sorted { $0.order < $1.order } }

    @discardableResult
    func create(_ name: String) async -> ChatGroupRecord? {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        return await save(ChatGroupRecord(name: String(clean.prefix(60)), order: (groups.map(\.order).max() ?? -1) + 1))
    }

    @discardableResult
    func save(_ value: ChatGroupRecord) async -> ChatGroupRecord? {
        var record = value
        let clean = record.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        record.name = String(clean.prefix(60))
        record.updatedAt = Date()
        do {
            try await store.save(record)
            await load()
            app?.sync.request()
            return record
        } catch { lastError = ErrorExplainer.explain(error).message; return nil }
    }

    func move(from offsets: IndexSet, to destination: Int) async {
        var ordered = groups
        let moving = offsets.sorted().map { ordered[$0] }
        for index in offsets.sorted(by: >) { ordered.remove(at: index) }
        let removedBeforeDestination = offsets.filter { $0 < destination }.count
        let insertion = min(max(0, destination - removedBeforeDestination), ordered.count)
        ordered.insert(contentsOf: moving, at: insertion)
        do {
            for index in ordered.indices {
                ordered[index].order = index
                ordered[index].updatedAt = Date()
                try await store.save(ordered[index])
            }
            await load()
            app?.sync.request()
        } catch { lastError = ErrorExplainer.explain(error).message }
    }

    func delete(_ id: UUID) async {
        do {
            try await store.delete(id)
            await app?.library.removeGroup(id)
            await load()
            app?.sync.request()
        } catch { lastError = ErrorExplainer.explain(error).message }
    }

    func name(for id: UUID?) -> String? {
        guard let id else { return nil }
        return groups.first { $0.id == id }?.name
    }
}
