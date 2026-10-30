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
        let redactor = SensitiveDataRedactor()
        var chats: [Chat] = []
        for file in files where file.pathExtension == "json" {
            guard let original = try? Data(contentsOf: file) else { continue }
            let data = (try? redactor.redactJSON(original)) ?? original
            do {
                let chat = try decoder.decode(Chat.self, from: data)
                chats.append(chat)
                if data != original { try? data.write(to: file, options: .atomic) }
            } catch {
                try? Quarantine.setAside(
                    fileURL: file,
                    dataDirectory: dataDirectory,
                    relativePath: "chats/" + file.lastPathComponent,
                    error: error
                )
            }
        }
        return chats.sorted { $0.updatedAt > $1.updatedAt }
    }

    public func load(_ id: UUID) -> Chat? {
        let file = url(for: id)
        guard let original = try? Data(contentsOf: file) else { return nil }
        let data = (try? SensitiveDataRedactor().redactJSON(original)) ?? original
        do {
            let chat = try JSONCoding.decoder().decode(Chat.self, from: data)
            if data != original { try? data.write(to: file, options: .atomic) }
            return chat
        } catch {
            try? Quarantine.setAside(fileURL: file, dataDirectory: dataDirectory, relativePath: Self.relativePath(for: id), error: error)
            return nil
        }
    }

    public func save(_ chat: Chat) throws {
        try FileManager.default.createDirectory(at: chatsDirectory, withIntermediateDirectories: true)
        let encoded = try JSONCoding.encoder(pretty: true).encode(chat)
        let data = try SensitiveDataRedactor().redactJSON(encoded)
        try data.write(to: url(for: chat.id), options: .atomic)
    }

    public func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: url(for: id))
    }

    /// Removes only a deleted group's association. Every chat and message remains intact.
    @discardableResult
    public func clearGroup(_ groupID: UUID) throws -> Int {
        var changed = 0
        for var chat in loadAll() where chat.groupID == groupID {
            chat.groupID = nil
            chat.updatedAt = Date()
            try save(chat)
            changed += 1
        }
        return changed
    }

    /// Writes any small JSON document (such as settings.json) into the mirrored folder.
    public func saveDocument<T: Encodable>(_ value: T, at relativePath: String) throws {
        let url = dataDirectory.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONCoding.encoder(pretty: true).encode(value).write(to: url, options: .atomic)
    }

    public func loadDocument<T: Decodable>(_ type: T.Type, at relativePath: String) -> T? {
        let url = dataDirectory.appendingPathComponent(relativePath)
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try JSONCoding.decoder().decode(type, from: data)
        } catch {
            try? Quarantine.setAside(fileURL: url, dataDirectory: dataDirectory, relativePath: relativePath, error: error)
            return nil
        }
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
