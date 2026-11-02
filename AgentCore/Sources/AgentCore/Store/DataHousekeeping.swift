import Foundation

public struct DataHousekeepingReport: Sendable, Hashable {
    public var removedOrphanBlobs = 0
    public var purgedTrashItems = 0
    public var compactedJobs = 0
}

/// Keeps MAIPA-G-data bounded without touching anything still referenced by a live chat, draft,
/// generated-picture record, or Recently Deleted entry.
public actor DataHousekeeping {
    private let dataDirectory: URL

    public init(dataDirectory: URL) {
        self.dataDirectory = dataDirectory
    }

    public func run(now: Date = Date()) async -> DataHousekeepingReport {
        var report = DataHousekeepingReport()
        report.compactedJobs = (try? await JobStore(dataDirectory: dataDirectory).compactFinished(now: now)) ?? 0
        report.purgedTrashItems = (try? await TrashStore(dataDirectory: dataDirectory).purgeExpired(now: now)) ?? 0
        let referenced = await referencedBlobPaths()
        report.removedOrphanBlobs = Self.removeOrphanBlobs(
            in: dataDirectory,
            referenced: referenced,
            olderThan: now.addingTimeInterval(-7 * 24 * 60 * 60)
        )
        return report
    }

    private func referencedBlobPaths() async -> Set<String> {
        var paths = Set<String>()
        func includeImage(_ image: GeneratedImageResult) {
            paths.insert(image.attachment.path)
            paths.insert(Self.generatedMetadataPath(image.id))
            if let mask = image.maskAttachment { paths.insert(mask.path) }
            if let parent = image.parentImageID { paths.insert(Self.generatedMetadataPath(parent)) }
        }
        func includeChat(_ chat: Chat) {
            for message in chat.messages {
                if case .user(let user) = message.body { paths.formUnion(user.attachments.map(\.path)) }
                if let turn = message.assistantTurn {
                    for image in turn.steps.flatMap({ $0.generatedImages ?? [] }) {
                        includeImage(image)
                    }
                }
            }
        }

        let chats = await ChatStore(dataDirectory: dataDirectory).loadAll()
        for chat in chats { includeChat(chat) }
        paths.formUnion(Self.draftAttachmentPaths(in: dataDirectory))

        let trash = await TrashStore(dataDirectory: dataDirectory).list()
        for entry in trash where entry.kind == .chat {
            guard let data = try? JSONCoding.encoder().encode(entry.payload),
                  let chat = try? JSONCoding.decoder().decode(Chat.self, from: data)
            else { continue }
            includeChat(chat)
        }
        return paths
    }

    /// FileManager's directory enumerator is intentionally confined to synchronous helpers. This
    /// keeps macOS/iOS Swift 6 from carrying a non-Sendable iterator across an actor suspension.
    private nonisolated static func draftAttachmentPaths(in dataDirectory: URL) -> Set<String> {
        var paths = Set<String>()
        let drafts = dataDirectory.appendingPathComponent(ComposerDraft.folder, isDirectory: true)
        if let files = FileManager.default.enumerator(at: drafts, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
            for case let url as URL in files where url.pathExtension == "json" {
                guard let data = try? Data(contentsOf: url),
                      let draft = try? JSONCoding.decoder().decode(ComposerDraft.self, from: data)
                else { continue }
                paths.formUnion(draft.attachments.map(\.path))
            }
        }
        return paths
    }

    private nonisolated static func removeOrphanBlobs(
        in dataDirectory: URL,
        referenced initialReferences: Set<String>,
        olderThan cutoff: Date
    ) -> Int {
        let manager = FileManager.default
        var referenced = initialReferences
        var removed = 0
        let media = dataDirectory.appendingPathComponent("media", isDirectory: true)

        struct MetadataRecord {
            var url: URL
            var result: GeneratedImageResult
            var modified: Date
        }
        var metadata: [MetadataRecord] = []
        if let files = manager.enumerator(at: media, includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey], options: [.skipsHiddenFiles]) {
            for case let url as URL in files where url.pathExtension == "json" {
                guard let data = try? Data(contentsOf: url),
                      let result = try? JSONCoding.decoder().decode(GeneratedImageResult.self, from: data)
                else { continue }
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantFuture
                metadata.append(MetadataRecord(url: url, result: result, modified: modified))
            }
        }
        var retainedIDs = Set(metadata.compactMap { record -> UUID? in
            let metadataPath = generatedMetadataPath(record.result.id)
            return referenced.contains(record.result.attachment.path)
                || referenced.contains(metadataPath)
                || record.modified >= cutoff ? record.result.id : nil
        })
        // Keep the complete source ancestry of a retained edit. Iterate to a fixed point so
        // metadata enumeration order cannot cause an older parent image to be deleted.
        var changed = true
        while changed {
            changed = false
            for record in metadata where retainedIDs.contains(record.result.id) {
                referenced.insert(record.result.attachment.path)
                referenced.insert(generatedMetadataPath(record.result.id))
                if let mask = record.result.maskAttachment { referenced.insert(mask.path) }
                if let parent = record.result.parentImageID, retainedIDs.insert(parent).inserted { changed = true }
            }
        }
        for record in metadata where !retainedIDs.contains(record.result.id) {
            if (try? manager.removeItem(at: record.url)) != nil { removed += 1 }
        }

        for folder in ["attachments", "media"] {
            let root = dataDirectory.appendingPathComponent(folder, isDirectory: true)
            guard let files = manager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for case let url as URL in files {
                guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey]),
                      values.isRegularFile == true,
                      (values.contentModificationDate ?? .distantFuture) < cutoff
                else { continue }
                let relative = relativePath(url, dataDirectory: dataDirectory)
                if url.pathExtension == "json" && folder == "media" { continue }
                guard !referenced.contains(relative) else { continue }
                if (try? manager.removeItem(at: url)) != nil { removed += 1 }
            }
        }
        removeEmptyDirectories(in: dataDirectory.appendingPathComponent("attachments", isDirectory: true))
        removeEmptyDirectories(in: media)
        return removed
    }

    private nonisolated static func generatedMetadataPath(_ id: UUID) -> String {
        "media/\(id.uuidString.lowercased()).json"
    }

    private nonisolated static func relativePath(_ url: URL, dataDirectory: URL) -> String {
        let root = dataDirectory.standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        return path.hasPrefix(root) ? String(path.dropFirst(root.count)) : ""
    }

    private nonisolated static func removeEmptyDirectories(in root: URL) {
        let manager = FileManager.default
        guard let enumerator = manager.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return }
        let directories = enumerator.compactMap { $0 as? URL }.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
        for directory in directories.sorted(by: { $0.path.count > $1.path.count }) {
            if (try? manager.contentsOfDirectory(atPath: directory.path).isEmpty) == true {
                try? manager.removeItem(at: directory)
            }
        }
    }
}
