import Foundation

public actor AttachmentStore {
    public static let maximumAttachmentBytes = 250 * 1024 * 1024
    public let dataDirectory: URL
    public init(dataDirectory: URL) { self.dataDirectory = dataDirectory }

    public func importData(_ data: Data, name: String, mimeType: String, kind: AttachmentKind) throws -> AttachmentReference {
        try write(data, name: name, mimeType: mimeType, kind: kind, folder: "attachments")
    }

    public func importFile(
        at sourceURL: URL,
        name: String,
        mimeType: String,
        kind: AttachmentKind,
        moveIfPossible: Bool = false
    ) throws -> AttachmentReference {
        let values = try sourceURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile != false else {
            throw ToolInputError("That attachment is not a regular file.")
        }
        let byteCount = values.fileSize ?? ((try? FileManager.default.attributesOfItem(atPath: sourceURL.path)[.size] as? Int) ?? 0)
        guard byteCount <= Self.maximumAttachmentBytes else {
            throw ToolInputError("That file is too large to save safely. Use a file smaller than 250 MB.")
        }
        let id = UUID()
        let cleanName = name.replacingOccurrences(of: "/", with: "-")
        let safeFileName = cleanName.isEmpty ? "attachment" : cleanName
        let path = "attachments/\(id.uuidString.lowercased())/\(safeFileName)"
        guard SnapshotStore.isSafeRelativePath(path) else { throw ToolInputError("That attachment name is not safe.") }
        let destination = dataDirectory.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if moveIfPossible, (try? FileManager.default.moveItem(at: sourceURL, to: destination)) != nil {
            return AttachmentReference(id: id, name: safeFileName, mimeType: mimeType, kind: kind, path: path, bytes: byteCount)
        }
        try FileManager.default.copyItem(at: sourceURL, to: destination)
        return AttachmentReference(id: id, name: safeFileName, mimeType: mimeType, kind: kind, path: path, bytes: byteCount)
    }

    public func importGeneratedImage(_ data: Data, name: String, mimeType: String) throws -> AttachmentReference {
        try write(data, name: name, mimeType: mimeType, kind: .image, folder: "media")
    }

    public func importWorkstationFile(_ data: Data, name: String, mimeType: String, kind: AttachmentKind) throws -> AttachmentReference {
        try write(data, name: name, mimeType: mimeType, kind: kind, folder: "attachments")
    }

    public func saveGeneratedMetadata(_ result: GeneratedImageResult) throws {
        let url = dataDirectory.appendingPathComponent("media/\(result.id.uuidString.lowercased()).json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONCoding.encoder(pretty: true).encode(result).write(to: url, options: .atomic)
    }

    public func generatedMetadata(_ id: UUID) throws -> GeneratedImageResult {
        try JSONCoding.decoder().decode(GeneratedImageResult.self, from: Data(contentsOf: dataDirectory.appendingPathComponent("media/\(id.uuidString.lowercased()).json")))
    }

    private func write(_ data: Data, name: String, mimeType: String, kind: AttachmentKind, folder: String) throws -> AttachmentReference {
        guard data.count <= Self.maximumAttachmentBytes else {
            throw ToolInputError("That file is too large to save safely. Use a file smaller than 250 MB.")
        }
        let id = UUID()
        let cleanName = name.replacingOccurrences(of: "/", with: "-")
        let safeFileName = cleanName.isEmpty ? "attachment" : cleanName
        let path = "\(folder)/\(id.uuidString.lowercased())/\(safeFileName)"
        guard SnapshotStore.isSafeRelativePath(path) else { throw ToolInputError("That attachment name is not safe.") }
        let url = dataDirectory.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        return AttachmentReference(id: id, name: safeFileName, mimeType: mimeType, kind: kind, path: path, bytes: data.count)
    }

    public nonisolated func fileURL(for attachment: AttachmentReference) throws -> URL {
        guard SnapshotStore.isSafeRelativePath(attachment.path) else { throw ToolInputError("That attachment path is not safe.") }
        return dataDirectory.appendingPathComponent(attachment.path)
    }

    public func data(for attachment: AttachmentReference) throws -> Data {
        let url = try fileURL(for: attachment)
        return try Data(contentsOf: url, options: .mappedIfSafe)
    }

    public func readPrefix(for attachment: AttachmentReference, maxBytes: Int) throws -> Data {
        let (slice, _) = try readSlice(for: attachment, offsetBytes: 0, maxBytes: maxBytes)
        return slice
    }

    public func readSlice(for attachment: AttachmentReference, offsetBytes: Int, maxBytes: Int) throws -> (data: Data, totalBytes: Int) {
        let url = try fileURL(for: attachment)
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let total = (attrs[.size] as? Int) ?? attachment.bytes
        let clampedOffset = max(0, min(offsetBytes, total))
        let clampedLength = max(0, min(maxBytes, total - clampedOffset))
        guard clampedLength > 0 else { return (Data(), total) }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        if clampedOffset > 0 {
            try handle.seek(toOffset: UInt64(clampedOffset))
        }
        let chunk = try handle.read(upToCount: clampedLength) ?? Data()
        return (chunk, total)
    }
}

public struct ReadAttachmentTool: AgentTool {
    public let attachments: [AttachmentReference]
    public let store: AttachmentStore
    public let name = "read_attachment"
    public init(attachments: [AttachmentReference], store: AttachmentStore) { self.attachments = attachments; self.store = store }
    public var spec: ToolSpec {
        ToolSpec(
            name: name,
            description: "Read a text attachment sent in this chat. Pass offset and limit to read large files (up to 250 MB) in sections.",
            parameters: [
                "type": "object",
                "properties": [
                    "name": ["type": "string", "description": "Attachment file name or ID."],
                    "offset": ["type": "integer", "description": "0-based offset to start reading from (character offset for files <= 2 MB; byte offset for files > 2 MB)."],
                    "limit": ["type": "integer", "description": "Maximum characters/bytes to return (default 200000, max 250000)."],
                ],
                "required": ["name"],
            ]
        )
    }
    public func runningSummary(for arguments: JSONValue) -> String { "Reading \(arguments.optionalString("name") ?? "attachment")…" }
    public func run(arguments: JSONValue, progress: @escaping @Sendable (String) -> Void) async throws -> ToolOutput {
        let requested = try arguments.requiredString("name")
        guard let attachment = attachments.last(where: { $0.name == requested || $0.id.uuidString.caseInsensitiveCompare(requested) == .orderedSame }) else {
            throw ToolInputError("There is no attachment named \(requested).")
        }
        guard attachment.kind == .text || attachment.kind == .file else {
            throw ToolInputError("\(attachment.name) is not a readable text attachment.")
        }
        let startOffset = max(0, arguments.optionalInt("offset") ?? 0)
        let maxWindow = min(250_000, max(1, arguments.optionalInt("limit") ?? 200_000))

        // Streamed window path for multi-megabyte files so 250 MB logs/CSVs never allocate a 250 MB String in RAM.
        if attachment.bytes > 2 * 1024 * 1024 {
            let (window, totalBytes) = try await store.readSlice(for: attachment, offsetBytes: startOffset, maxBytes: maxWindow)
            guard startOffset < totalBytes else {
                return ToolOutput(
                    forModel: "\(attachment.name) (\(totalBytes) bytes): offset \(startOffset) is at or past the end.",
                    summary: "Read attachment \(attachment.name)",
                    detail: ""
                )
            }
            let slice = String(decoding: window, as: UTF8.self)
            let endOffset = startOffset + window.count
            let moreNote = endOffset < totalBytes
                ? "\n\n[Showing bytes \(startOffset)..<\(endOffset) of \(totalBytes). Call read_attachment with name \"\(attachment.name)\" and offset \(endOffset) to read the next section.]"
                : ""
            return ToolOutput(
                forModel: "\(attachment.name) (\(totalBytes) bytes)\n\(slice)\(moreNote)",
                summary: endOffset < totalBytes ? "Read \(attachment.name) (\(startOffset)–\(endOffset) of \(totalBytes) bytes)" : "Read attachment \(attachment.name)",
                detail: String(slice.prefix(20_000))
            )
        }

        let data = try await store.data(for: attachment)
        guard data.count <= AttachmentStore.maximumAttachmentBytes else {
            throw ToolInputError("\(attachment.name) is too large to read as text.")
        }
        let fullText = String(decoding: data, as: UTF8.self)
        let total = fullText.count
        guard startOffset <= total else {
            return ToolOutput(forModel: "\(attachment.name) (\(data.count) bytes, \(total) characters): offset \(startOffset) is at or past the end.", summary: "Read attachment \(attachment.name)", detail: "")
        }
        let startIndex = fullText.index(fullText.startIndex, offsetBy: startOffset)
        let endOffset = min(total, startOffset + maxWindow)
        let endIndex = fullText.index(startIndex, offsetBy: endOffset - startOffset)
        let slice = String(fullText[startIndex..<endIndex])
        let moreNote = endOffset < total
            ? "\n\n[Showing characters \(startOffset)..<\(endOffset) of \(total). Call read_attachment with name \"\(attachment.name)\" and offset \(endOffset) to read the next section.]"
            : ""
        return ToolOutput(
            forModel: "\(attachment.name) (\(data.count) bytes, \(total) characters)\n\(slice)\(moreNote)",
            summary: endOffset < total ? "Read \(attachment.name) (\(startOffset)–\(endOffset) of \(total) chars)" : "Read attachment \(attachment.name)",
            detail: String(slice.prefix(20_000))
        )
    }
}
