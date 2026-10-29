import Foundation

/// Saves chats as one JSON file each, in the folder that is mirrored to the user's private
/// MAIPA-G-data repo. Files are written whole and swapped in, so a crash or a sync running at the
/// same moment can never see half a file.
public actor ChatStore {
    public nonisolated let dataDirectory: URL
    private var chatsDirectory: URL { dataDirectory.appendingPathComponent("chats", isDirectory: true) }

    public init(dataDirectory: URL) {
        self.dataDirectory = dataDirectory
    }

    public static func relativePath(for id: UUID) -> String { "chats/\(id.uuidString.lowercased()).json" }

    public func url(for id: UUID) -> URL {
        dataDirectory.appendingPathComponent(Self.relativePath(for: id))
    }

    /// Every saved chat, newest first. A file that can't be read is set aside, not deleted.
    public func loadAll() -> [Chat] {
        let manager = FileManager.default
        guard let files = try? manager.contentsOfDirectory(at: chatsDirectory, includingPropertiesForKeys: nil) else { return [] }
        let decoder = JSONCoding.decoder()
        var chats: [Chat] = []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file) else { continue }
            if let chat = try? decoder.decode(Chat.self, from: data) {
                chats.append(chat)
            } else {
                let aside = dataDirectory.deletingLastPathComponent().appendingPathComponent("Unreadable", isDirectory: true)
                try? manager.createDirectory(at: aside, withIntermediateDirectories: true)
                try? manager.moveItem(at: file, to: aside.appendingPathComponent(file.lastPathComponent + ".\(Int(Date().timeIntervalSince1970))"))
            }
        }
        return chats.sorted { $0.updatedAt > $1.updatedAt }
    }

    public func load(_ id: UUID) -> Chat? {
        guard let data = try? Data(contentsOf: url(for: id)) else { return nil }
        return try? JSONCoding.decoder().decode(Chat.self, from: data)
    }

    public func save(_ chat: Chat) throws {
        try FileManager.default.createDirectory(at: chatsDirectory, withIntermediateDirectories: true)
        let data = try JSONCoding.encoder(pretty: true).encode(chat)
        try data.write(to: url(for: chat.id), options: .atomic)
    }

    public func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: url(for: id))
    }

    /// Writes any small JSON document (such as settings.json) into the mirrored folder.
    public func saveDocument<T: Encodable>(_ value: T, at relativePath: String) throws {
        let url = dataDirectory.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONCoding.encoder(pretty: true).encode(value).write(to: url, options: .atomic)
    }

    public func loadDocument<T: Decodable>(_ type: T.Type, at relativePath: String) -> T? {
        guard let data = try? Data(contentsOf: dataDirectory.appendingPathComponent(relativePath)) else { return nil }
        return try? JSONCoding.decoder().decode(type, from: data)
    }

    /// Writes attachment/media bytes atomically inside the mirrored folder.
    public func saveBlob(_ data: Data, at relativePath: String) throws {
        guard SnapshotStore.isSafeRelativePath(relativePath) else { throw CocoaError(.fileWriteInvalidFileName) }
        let url = dataDirectory.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    public func loadBlob(at relativePath: String) -> Data? {
        guard SnapshotStore.isSafeRelativePath(relativePath) else { return nil }
        return try? Data(contentsOf: dataDirectory.appendingPathComponent(relativePath))
    }

    public func deleteItem(at relativePath: String) throws {
        guard SnapshotStore.isSafeRelativePath(relativePath) else { throw CocoaError(.fileWriteInvalidFileName) }
        let url = dataDirectory.appendingPathComponent(relativePath)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}
