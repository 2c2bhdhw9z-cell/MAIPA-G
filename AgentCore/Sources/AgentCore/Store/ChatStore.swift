import Foundation

/// Saves chats as one JSON file each, in the folder that is mirrored to the user's private
/// MAIPA-G-data repo. Files are written whole and swapped in, so a crash or a sync running at the
/// same moment can never see half a file.
public actor ChatStore {
    public nonisolated let dataDirectory: URL
    private nonisolated var chatsDirectory: URL { dataDirectory.appendingPathComponent("chats", isDirectory: true) }
    /// Chat files already known to have no secret in them, by name, with their size and change
    /// date: written by `save` (which redacts) or checked by `scrub`. Only others are checked again.
    private var checkedFiles: [String: FileStamp] = [:]

    struct FileStamp: Equatable {
        var size: Int
        var modified: Date
    }

    public init(dataDirectory: URL) {
        self.dataDirectory = dataDirectory
    }

    public static func relativePath(for id: UUID) -> String { "chats/\(id.uuidString.lowercased()).json" }

    public nonisolated func url(for id: UUID) -> URL {
        dataDirectory.appendingPathComponent(Self.relativePath(for: id))
    }

    static func stamp(_ file: URL) -> FileStamp? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              let size = (attributes[.size] as? NSNumber)?.intValue,
              let modified = attributes[.modificationDate] as? Date else { return nil }
        return FileStamp(size: size, modified: modified)
    }

    /// Every saved chat, newest first. A file that can't be read is set aside, not deleted.
    public func loadAll() -> [Chat] {
        let manager = FileManager.default
        guard let files = try? manager.contentsOfDirectory(at: chatsDirectory, includingPropertiesForKeys: nil) else { return [] }
        let decoder = JSONCoding.decoder()
        var chats: [Chat] = []
        var toCheck: [(URL, Data)] = []
        for file in files where file.pathExtension == "json" {
            guard let original = try? Data(contentsOf: file) else { continue }
            do {
                chats.append(try decoder.decode(Chat.self, from: original))
                toCheck.append((file, original))
            } catch {
                try? Quarantine.setAside(
                    fileURL: file,
                    dataDirectory: dataDirectory,
                    relativePath: "chats/" + file.lastPathComponent,
                    error: error
                )
            }
        }
        // Checked for secrets afterwards, not before the list is shown (see `load`).
        if !toCheck.isEmpty { Task { for (file, original) in toCheck { await self.scrub(file, original: original) } } }
        return chats.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// One chat, read and decoded away from this actor and the main thread, so opening a chat never
    /// waits behind a save of another one (each of the owner's big chats took seconds to save).
    /// The file is checked for secrets afterwards, in the background: every save already redacts,
    /// and a 12 MB chat took 5 seconds to check on every open (owner, 16 November 2026: opening a
    /// chat took about 30 seconds).
    public nonisolated func load(_ id: UUID) async -> Chat? {
        let file = url(for: id)
        let relativePath = Self.relativePath(for: id)
        let dataDirectory = dataDirectory
        let read = await Task.detached(priority: .userInitiated) { () -> (chat: Chat?, original: Data?) in
            guard let original = try? Data(contentsOf: file) else { return (nil, nil) }
            do {
                return (try JSONCoding.decoder().decode(Chat.self, from: original), original)
            } catch {
                try? Quarantine.setAside(fileURL: file, dataDirectory: dataDirectory, relativePath: relativePath, error: error)
                return (nil, nil)
            }
        }.value
        if read.chat != nil, let original = read.original {
            Task { await self.scrub(file, original: original) }
        }
        return read.chat
    }

    /// Takes a secret out of a chat file that has one (from another device, or saved before
    /// redaction existed), only over the same bytes it read: a save since then is redacted already.
    func scrub(_ file: URL, original: Data) {
        let name = file.lastPathComponent
        if let stamp = Self.stamp(file), checkedFiles[name] == stamp { return }
        guard let redacted = try? SensitiveDataRedactor().redactJSON(original) else { return }
        if redacted != original {
            guard (try? Data(contentsOf: file)) == original else { return }
            try? redacted.write(to: file, options: .atomic)
        }
        if let stamp = Self.stamp(file) { checkedFiles[name] = stamp }
    }

    public func save(_ chat: Chat) throws {
        try FileManager.default.createDirectory(at: chatsDirectory, withIntermediateDirectories: true)
        let encoded = try JSONCoding.encoder(pretty: true).encode(chat)
        let data = try SensitiveDataRedactor().redactJSON(encoded)
        let file = url(for: chat.id)
        try data.write(to: file, options: .atomic)
        if let stamp = Self.stamp(file) { checkedFiles[file.lastPathComponent] = stamp }
    }

    /// A small JSON document read away from this actor, like `load`, so it doesn't wait for a save.
    public nonisolated func readDocument<T: Decodable & Sendable>(_ type: T.Type, at relativePath: String) async -> T? {
        let url = dataDirectory.appendingPathComponent(relativePath)
        let dataDirectory = dataDirectory
        return await Task.detached(priority: .userInitiated) { () -> T? in
            guard let data = try? Data(contentsOf: url) else { return nil }
            do {
                return try JSONCoding.decoder().decode(type, from: data)
            } catch {
                try? Quarantine.setAside(fileURL: url, dataDirectory: dataDirectory, relativePath: relativePath, error: error)
                return nil
            }
        }.value
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
