import Foundation

public actor AttachmentStore {
    public let dataDirectory: URL
    public init(dataDirectory: URL) { self.dataDirectory = dataDirectory }

    public func importData(_ data: Data, name: String, mimeType: String, kind: AttachmentKind) throws -> AttachmentReference {
        try write(data, name: name, mimeType: mimeType, kind: kind, folder: "attachments")
    }

    public func importGeneratedImage(_ data: Data, name: String, mimeType: String) throws -> AttachmentReference {
        try write(data, name: name, mimeType: mimeType, kind: .image, folder: "media")
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
        let maximumBytes = 25 * 1024 * 1024
        guard data.count <= maximumBytes else {
            throw ToolInputError("That file is too large to save safely. Use a file smaller than 25 MB.")
        }
        let id = UUID()
        let cleanName = name.replacingOccurrences(of: "/", with: "-")
        let path = "\(folder)/\(id.uuidString.lowercased())/\(cleanName.isEmpty ? "attachment" : cleanName)"
        guard SnapshotStore.isSafeRelativePath(path) else { throw ToolInputError("That attachment name is not safe.") }
        let url = dataDirectory.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        return AttachmentReference(id: id, name: cleanName, mimeType: mimeType, kind: kind, path: path, bytes: data.count)
    }

    public func data(for attachment: AttachmentReference) throws -> Data {
        guard SnapshotStore.isSafeRelativePath(attachment.path) else { throw ToolInputError("That attachment path is not safe.") }
        return try Data(contentsOf: dataDirectory.appendingPathComponent(attachment.path))
    }
}

public struct ReadAttachmentTool: AgentTool {
    public let attachments: [AttachmentReference]
    public let store: AttachmentStore
    public let name = "read_attachment"
    public init(attachments: [AttachmentReference], store: AttachmentStore) { self.attachments = attachments; self.store = store }
    public var spec: ToolSpec { ToolSpec(name: name, description: "Read a text attachment sent in this chat.", parameters: ["type": "object", "properties": ["name": ["type": "string"]], "required": ["name"]]) }
    public func runningSummary(for arguments: JSONValue) -> String { "Reading \(arguments.optionalString("name") ?? "attachment")…" }
    public func run(arguments: JSONValue, progress: @escaping @Sendable (String) -> Void) async throws -> ToolOutput {
        let requested = try arguments.requiredString("name")
        guard let attachment = attachments.last(where: { $0.name == requested || $0.id.uuidString == requested }) else { throw ToolInputError("There is no attachment named \(requested).") }
        guard attachment.kind == .text else { throw ToolInputError("\(attachment.name) is not a text attachment.") }
        let data = try await store.data(for: attachment)
        guard data.count <= 1_000_000 else { throw ToolInputError("\(attachment.name) is too large to read as text.") }
        let text = String(decoding: data, as: UTF8.self)
        return ToolOutput(forModel: "\(attachment.name) (\(data.count) bytes)\n\(text)", summary: "Read attachment \(attachment.name)", detail: String(text.prefix(20_000)))
    }
}
