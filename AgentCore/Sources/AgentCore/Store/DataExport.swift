import Foundation
import ZIPFoundation

public enum DataExport {
    /// Creates a self-contained ZIP without following symlinks or including files outside the
    /// mirrored data directory.
    public static func makeArchive(dataDirectory: URL, destination: URL, date: Date = Date()) throws {
        let manager = FileManager.default
        try? manager.removeItem(at: destination)
        guard let archive = Archive(url: destination, accessMode: .create) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let rootName = "MAIPA-G-export-" + String(ISO8601.string(from: date).prefix(10))
        guard let enumerator = manager.enumerator(
            at: dataDirectory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { throw CocoaError(.fileReadUnknown) }

        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            let root = dataDirectory.standardizedFileURL.path + "/"
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(root) else { continue }
            let relative = String(path.dropFirst(root.count))
            guard SnapshotStore.isSafeRelativePath(relative) else { continue }
            let ext = url.pathExtension.lowercased()
            let alreadyCompressed = ["jpg", "jpeg", "png", "gif", "webp", "heic", "pdf", "zip", "mp4", "mov"].contains(ext)
            try archive.addEntry(
                with: "\(rootName)/data/\(relative)",
                fileURL: url,
                compressionMethod: alreadyCompressed ? .none : .deflate
            )
        }

        let manifest: JSONValue = [
            "format": 1,
            "createdAt": .string(ISO8601.string(from: date)),
            "root": .string(rootName),
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
