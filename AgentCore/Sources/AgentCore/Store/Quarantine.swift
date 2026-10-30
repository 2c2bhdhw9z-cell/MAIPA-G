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
