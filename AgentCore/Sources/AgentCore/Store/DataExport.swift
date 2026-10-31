import Foundation
import ZIPFoundation

public enum DataExport {
    /// Creates a self-contained ZIP without following symlinks or including caches or Keychain
    /// credentials. It includes mirrored data, quarantined bytes, and sync metadata.
    public static func makeArchive(dataDirectory: URL, destination: URL, date: Date = Date()) throws {
        let manager = FileManager.default
        try? manager.removeItem(at: destination)
        guard let archive = Archive(url: destination, accessMode: .create) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let rootName = "MAIPA-G-export-" + String(ISO8601.string(from: date).prefix(10))

        func addFiles(from base: URL, under archiveFolder: String, required: Bool) throws {
            guard manager.fileExists(atPath: base.path) else {
                if required { throw CocoaError(.fileReadNoSuchFile) }
                return
            }
            guard let enumerator = manager.enumerator(
                at: base,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            ) else {
                if required { throw CocoaError(.fileReadUnknown) }
                return
            }
            let root = base.standardizedFileURL.path + "/"
            for case let url as URL in enumerator {
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
                let path = url.standardizedFileURL.path
                guard path.hasPrefix(root) else { continue }
                let relative = String(path.dropFirst(root.count))
                guard SnapshotStore.isSafeRelativePath(relative) else { continue }
                let ext = url.pathExtension.lowercased()
                let alreadyCompressed: Set<String> = [
                    "jpg", "jpeg", "png", "gif", "webp", "heic", "pdf",
                    "zip", "ipa", "gz", "tgz", "bz2", "xz", "7z", "rar",
                    "mp4", "mov", "mp3", "m4a", "aac", "ogg", "flac", "opus", "bin",
                ]
                try archive.addEntry(
                    with: "\(rootName)/\(archiveFolder)/\(relative)",
                    fileURL: url,
                    compressionMethod: alreadyCompressed.contains(ext) ? .none : .deflate
                )
            }
        }

        try addFiles(from: dataDirectory, under: "data", required: true)
        let support = dataDirectory.deletingLastPathComponent()
        try addFiles(from: support.appendingPathComponent("Unreadable", isDirectory: true), under: "Unreadable", required: false)
        let syncState = support.appendingPathComponent("sync-state.json")
        if manager.fileExists(atPath: syncState.path) {
            try archive.addEntry(with: "\(rootName)/sync-state.json", fileURL: syncState, compressionMethod: .deflate)
        }

        let manifest: JSONValue = [
            "format": 1,
            "createdAt": .string(ISO8601.string(from: date)),
            "root": .string(rootName),
            "includes": ["data", "Unreadable", "sync-state.json"],
        ]
        let data = try JSONCoding.encoder(pretty: true).encode(manifest)
        try archive.addEntry(
            with: "\(rootName)/manifest.json",
            type: .file,
            uncompressedSize: Int64(data.count),
            compressionMethod: .deflate,
            provider: { position, size in
                let start = Int(position)
                guard start < data.count else { return Data() }
                return data.subdata(in: start..<min(start + size, data.count))
            }
        )
    }
}
