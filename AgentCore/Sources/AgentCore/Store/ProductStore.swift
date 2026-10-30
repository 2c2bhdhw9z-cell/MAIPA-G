import Foundation

/// Typed, atomic JSON storage for records that live beside chats in MAIPA-G-data.
public actor ProductStore<Record: ProductRecord> {
    public let dataDirectory: URL
    public let folder: String

    public init(dataDirectory: URL, folder: String) {
        self.dataDirectory = dataDirectory
        self.folder = folder
    }

    public func relativePath(for id: UUID) -> String { "\(folder)/\(id.uuidString.lowercased()).json" }

    public func loadAll() -> [Record] {
        let directory = dataDirectory.appendingPathComponent(folder, isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return [] }
        var records: [Record] = []
        for url in files where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url) else { continue }
            do {
                records.append(try JSONCoding.decoder().decode(Record.self, from: data))
            } catch {
                try? Quarantine.setAside(
                    fileURL: url,
                    dataDirectory: dataDirectory,
                    relativePath: "\(folder)/\(url.lastPathComponent)",
                    error: error
                )
            }
        }
        return records.sorted { $0.updatedAt > $1.updatedAt }
    }

    public func load(_ id: UUID) -> Record? {
        let url = dataDirectory.appendingPathComponent(relativePath(for: id))
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try JSONCoding.decoder().decode(Record.self, from: data)
        } catch {
            try? Quarantine.setAside(fileURL: url, dataDirectory: dataDirectory, relativePath: relativePath(for: id), error: error)
            return nil
        }
    }

    public func save(_ record: Record) throws {
        let url = dataDirectory.appendingPathComponent(relativePath(for: record.id))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONCoding.encoder(pretty: true).encode(record).write(to: url, options: .atomic)
    }

    public func delete(_ id: UUID) throws {
        let url = dataDirectory.appendingPathComponent(relativePath(for: id))
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}
