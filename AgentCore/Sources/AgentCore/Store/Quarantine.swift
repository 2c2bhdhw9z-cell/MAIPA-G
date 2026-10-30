import Foundation

public struct QuarantineRecord: Codable, Sendable, Hashable {
    public var format: Int
    public var originalPath: String
    public var quarantinedPath: String
    public var blobID: String
    public var bytes: Int
    public var reason: String
    public var quarantinedAt: Date
}

/// Sets undecodable records aside with their bytes and reason. The original path remains held so
/// DataRepoSync never mistakes an unreadable file for an intentional deletion.
public enum Quarantine {
    public static func setAside(fileURL: URL, dataDirectory: URL, relativePath: String, error: Error) throws {
        guard SnapshotStore.isSafeRelativePath(relativePath) else { throw CocoaError(.fileReadInvalidFileName) }
        let data = try Data(contentsOf: fileURL)
        let root = dataDirectory.deletingLastPathComponent().appendingPathComponent("Unreadable", isDirectory: true)
        let suffix = "\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.lowercased())"
        let relativeDestination = relativePath + "." + suffix
        let destination = root.appendingPathComponent(relativeDestination)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: destination, options: .atomic)
        let record = QuarantineRecord(
            format: 1,
            originalPath: relativePath,
            quarantinedPath: relativeDestination,
            blobID: Hashing.gitBlobID(data),
            bytes: data.count,
            reason: String(describing: error),
            quarantinedAt: Date()
        )
        try JSONCoding.encoder(pretty: true).encode(record).write(
            to: destination.appendingPathExtension("reason.json"), options: .atomic
        )
        try FileManager.default.removeItem(at: fileURL)
    }

    public static func quarantinedFile(for record: QuarantineRecord, dataDirectory: URL) -> URL {
        dataDirectory.deletingLastPathComponent()
            .appendingPathComponent("Unreadable", isDirectory: true)
            .appendingPathComponent(record.quarantinedPath)
    }

    public static func retry(_ record: QuarantineRecord, dataDirectory: URL) throws {
        let source = quarantinedFile(for: record, dataDirectory: dataDirectory)
        let destination = dataDirectory.appendingPathComponent(record.originalPath)
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw CocoaError(.fileWriteFileExists) }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: source, to: destination)
        try? FileManager.default.removeItem(at: source.appendingPathExtension("reason.json"))
    }

    public static func discard(_ record: QuarantineRecord, dataDirectory: URL) throws {
        let source = quarantinedFile(for: record, dataDirectory: dataDirectory)
        if FileManager.default.fileExists(atPath: source.path) { try FileManager.default.removeItem(at: source) }
        let reason = source.appendingPathExtension("reason.json")
        if FileManager.default.fileExists(atPath: reason.path) { try FileManager.default.removeItem(at: reason) }
    }

    public static func records(dataDirectory: URL) -> [QuarantineRecord] {
        let root = dataDirectory.deletingLastPathComponent().appendingPathComponent("Unreadable", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { return [] }
        var records: [QuarantineRecord] = []
        for case let url as URL in enumerator where url.lastPathComponent.hasSuffix(".reason.json") {
            guard let data = try? Data(contentsOf: url), let record = try? JSONCoding.decoder().decode(QuarantineRecord.self, from: data) else { continue }
            records.append(record)
        }
        return records
    }
}
