import Foundation

public enum TrashKind: String, Codable, Sendable, CaseIterable {
    case chat, memory, agent, workflow

    public var label: String {
        switch self {
        case .chat: "Chat"
        case .memory: "Memory"
        case .agent: "Agent"
        case .workflow: "Workflow"
        }
    }
}

public struct TrashEntry: Codable, Sendable, Hashable, Identifiable {
    public var format: Int
    public var id: UUID
    public var kind: TrashKind
    public var title: String
    public var originalPath: String
    public var deletedAt: Date
    public var updatedAt: Date
    public var payload: JSONValue

    public var expiresAt: Date { deletedAt.addingTimeInterval(30 * 24 * 60 * 60) }
}

/// Moves deleted product records into the synced trash for 30 days without changing their schema.
public actor TrashStore {
    private let dataDirectory: URL
    private var trashDirectory: URL { dataDirectory.appendingPathComponent("trash", isDirectory: true) }

    public init(dataDirectory: URL) { self.dataDirectory = dataDirectory }

    public func move(id: UUID, kind: TrashKind, title: String, originalPath: String) throws {
        guard SnapshotStore.isSafeRelativePath(originalPath) else { throw CocoaError(.fileReadInvalidFileName) }
        let source = dataDirectory.appendingPathComponent(originalPath)
        let data = try Data(contentsOf: source)
        guard let payload = JSONValue.parse(data) else { throw CocoaError(.fileReadCorruptFile) }
        let now = Date()
        let entry = TrashEntry(
            format: 1, id: id, kind: kind, title: title, originalPath: originalPath,
            deletedAt: now, updatedAt: now, payload: payload
        )
        let destination = url(for: entry)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONCoding.encoder(pretty: true).encode(entry).write(to: destination, options: .atomic)
        try FileManager.default.removeItem(at: source)
    }

    public func list() -> [TrashEntry] {
        guard let enumerator = FileManager.default.enumerator(at: trashDirectory, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { return [] }
        var entries: [TrashEntry] = []
        for case let url as URL in enumerator where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url), let entry = try? JSONCoding.decoder().decode(TrashEntry.self, from: data) else { continue }
            entries.append(entry)
        }
        return entries.sorted { $0.deletedAt > $1.deletedAt }
    }

    public func restore(_ entry: TrashEntry) throws {
        guard SnapshotStore.isSafeRelativePath(entry.originalPath) else { throw CocoaError(.fileWriteInvalidFileName) }
        let destination = dataDirectory.appendingPathComponent(entry.originalPath)
        // Never overwrite a live item that was recreated on another device.
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw CocoaError(.fileWriteFileExists) }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONCoding.encoder(pretty: true).encode(entry.payload).write(to: destination, options: .atomic)
        try FileManager.default.removeItem(at: url(for: entry))
    }

    public func deleteForever(_ entry: TrashEntry) throws {
        let target = url(for: entry)
        if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
    }

    @discardableResult
    public func purgeExpired(now: Date = Date()) throws -> Int {
        let expired = list().filter { $0.expiresAt <= now }
        for entry in expired { try deleteForever(entry) }
        return expired.count
    }

    private func url(for entry: TrashEntry) -> URL {
        trashDirectory.appendingPathComponent(entry.kind.rawValue, isDirectory: true)
            .appendingPathComponent(entry.id.uuidString.lowercased() + ".json")
    }
}
