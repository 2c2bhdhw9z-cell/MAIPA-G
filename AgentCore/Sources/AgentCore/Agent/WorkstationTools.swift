import Foundation

public struct WorkstationFileItem: Sendable, Hashable {
    public var id: String
    public var name: String
    public var mimeType: String
    public var byteCount: Int
    public var source: String
    public var attachment: AttachmentReference?
    public var stagedPath: String?

    public init(
        id: String,
        name: String,
        mimeType: String,
        byteCount: Int,
        source: String,
        attachment: AttachmentReference? = nil,
        stagedPath: String? = nil
    ) {
        self.id = id
        self.name = name
        self.mimeType = mimeType
        self.byteCount = byteCount
        self.source = source
        self.attachment = attachment
        self.stagedPath = stagedPath
    }
}

public struct ListWorkstationFilesTool: AgentTool {
    public let name = "list_workstation_files"
    private let listProvider: @Sendable () async -> [WorkstationFileItem]

    public init(listProvider: @escaping @Sendable () async -> [WorkstationFileItem]) {
        self.listProvider = listProvider
    }

    public var spec: ToolSpec {
        ToolSpec(
            name: name,
            description: "List all files currently in this chat's Workstation (uploaded attachments, Canvas/HTML/Mermaid artifacts, generated media, and staged repo files).",
            parameters: [
                "type": "object",
                "properties": [:],
                "additionalProperties": false,
            ]
        )
    }

    public func runningSummary(for arguments: JSONValue) -> String { "Listing Workstation files…" }

    public func run(arguments: JSONValue, progress: @escaping @Sendable (String) -> Void) async throws -> ToolOutput {
        let items = await listProvider()
        guard !items.isEmpty else {
            return ToolOutput(forModel: "Workstation has no files in this chat yet.", summary: "Workstation · 0 files", detail: "No files")
        }
        let lines = items.map { item in
            "- \(item.name) [id: \(item.id), source: \(item.source), type: \(item.mimeType), size: \(Format.bytes(item.byteCount))]"
        }.joined(separator: "\n")
        return ToolOutput(
            forModel: "Workstation files (\(items.count)):\n\(lines)",
            summary: "Listed \(items.count) Workstation file\(items.count == 1 ? "" : "s")",
            detail: lines
        )
    }
}

public struct ReadWorkstationFileTool: AgentTool {
    public let name = "read_workstation_file"
    private let store: AttachmentStore
    private let listProvider: @Sendable () async -> [WorkstationFileItem]
    private let readStagedText: (@Sendable (String) async throws -> String?)?

    public init(
        store: AttachmentStore,
        listProvider: @escaping @Sendable () async -> [WorkstationFileItem],
        readStagedText: (@Sendable (String) async throws -> String?)? = nil
    ) {
        self.store = store
        self.listProvider = listProvider
        self.readStagedText = readStagedText
    }

    public var spec: ToolSpec {
        ToolSpec(
            name: name,
            description: "Read a text, code, Markdown, HTML, SVG, Mermaid, JSON, or CSV file from this chat's Workstation by file name or id, with optional byte `offset` and `limit` pagination.",
            parameters: [
                "type": "object",
                "properties": [
                    "name": ["type": "string", "description": "File name or Workstation item id from `list_workstation_files`."],
                    "offset": ["type": "integer", "description": "Byte offset to start reading from (default 0)."],
                    "limit": ["type": "integer", "description": "Maximum bytes to read in this slice (default 80000, max 200000)."],
                ],
                "required": ["name"],
                "additionalProperties": false,
            ]
        )
    }

    public var bringsOutsideContent: Bool { true }

    public func runningSummary(for arguments: JSONValue) -> String {
        "Reading Workstation file \(arguments.optionalString("name") ?? "")…"
    }

    public func run(arguments: JSONValue, progress: @escaping @Sendable (String) -> Void) async throws -> ToolOutput {
        let query = try arguments.requiredString("name").trimmingCharacters(in: .whitespacesAndNewlines)
        let offset = max(0, arguments.optionalInt("offset") ?? 0)
        let limit = min(max(arguments.optionalInt("limit") ?? 80_000, 1_024), 200_000)
        let items = await listProvider()
        guard let match = items.first(where: {
            $0.id.caseInsensitiveCompare(query) == .orderedSame
                || $0.name.caseInsensitiveCompare(query) == .orderedSame
                || ($0.stagedPath?.caseInsensitiveCompare(query) == .orderedSame)
        }) ?? items.first(where: { $0.name.localizedCaseInsensitiveContains(query) }) else {
            throw ToolInputError("No Workstation file matches \"\(query)\". Call `list_workstation_files` to inspect available files.")
        }

        if let stagedPath = match.stagedPath, let readStagedText, let fullText = try await readStagedText(stagedPath) {
            let utf8 = Data(fullText.utf8)
            let start = min(offset, utf8.count)
            let end = min(utf8.count, start + limit)
            let sliceText = String(decoding: utf8[start..<end], as: UTF8.self)
            let header = "Workstation file: \(match.name) (staged repo file `\(stagedPath)`, bytes \(start)..<\(end) of \(utf8.count))"
            return ToolOutput(forModel: "\(header)\n\(sliceText)", summary: "Read \(match.name)", detail: String(sliceText.prefix(2_000)))
        }

        guard let attachment = match.attachment else {
            throw ToolInputError("\(match.name) has no readable local storage reference.")
        }
        if attachment.kind == .pdf {
            let data = try await store.data(for: attachment)
            if let extracted = PDFTextExtractor.extractText(from: data) {
                let utf8 = Data(extracted.utf8)
                let start = min(offset, utf8.count)
                let end = min(utf8.count, start + limit)
                let sliceText = String(decoding: utf8[start..<end], as: UTF8.self)
                return ToolOutput(
                    forModel: "Workstation PDF \(match.name) (extracted text, bytes \(start)..<\(end) of \(utf8.count)):\n\(sliceText)",
                    summary: "Read PDF \(match.name)",
                    detail: String(sliceText.prefix(2_000))
                )
            }
        }
        let (slice, totalBytes) = try await store.readSlice(for: attachment, offsetBytes: offset, maxBytes: limit)
        if BinaryImageInspector.inspect(slice, path: match.name) != nil || attachment.kind == .image {
            let full = totalBytes <= 12 * 1024 * 1024 ? (try? await store.data(for: attachment)) : nil
            if let full {
                return ToolOutput(
                    forModel: "Loaded Workstation image \(match.name) (\(attachment.mimeType), \(Format.bytes(totalBytes))).",
                    summary: "Viewed \(match.name)",
                    detail: "\(match.name) (\(Format.bytes(totalBytes)))",
                    inlineImages: [ToolInlineImage(name: match.name, mimeType: attachment.mimeType, data: full)]
                )
            }
        }
        let decoded = String(decoding: slice, as: UTF8.self)
        let moreNote = offset + slice.count < totalBytes ? "\n[More bytes available: pass offset=\(offset + slice.count) to continue reading]" : ""
        return ToolOutput(
            forModel: "Workstation file: \(match.name) (\(match.mimeType), bytes \(offset)..<\(offset + slice.count) of \(totalBytes))\n\(decoded)\(moreNote)",
            summary: "Read \(match.name)",
            detail: String(decoded.prefix(2_000))
        )
    }
}

public struct WriteWorkstationFileTool: AgentTool {
    public let name = "write_workstation_file"
    private let store: AttachmentStore
    private let onWritten: @Sendable (AttachmentReference, String) async -> Void

    public init(
        store: AttachmentStore,
        onWritten: @escaping @Sendable (AttachmentReference, String) async -> Void
    ) {
        self.store = store
        self.onWritten = onWritten
    }

    public var spec: ToolSpec {
        ToolSpec(
            name: name,
            description: "Create or update a file in this chat's Workstation (such as an `.html` interactive preview, `.mmd` Mermaid diagram, `.svg` graphic, `.md` report, `.json`/`.csv` dataset, or source file) so the person can view, interact with, or export it immediately in Workstation.",
            parameters: [
                "type": "object",
                "properties": [
                    "name": ["type": "string", "description": "File name with extension (for example `dashboard.html`, `architecture.mmd`, `report.md`, or `data.csv`)."],
                    "content": ["type": "string", "description": "Complete UTF-8 file content."],
                    "mime_type": ["type": "string", "description": "Optional MIME type override (inferred automatically from extension when omitted)."],
                ],
                "required": ["name", "content"],
                "additionalProperties": false,
            ]
        )
    }

    public func runningSummary(for arguments: JSONValue) -> String {
        "Saving \(arguments.optionalString("name") ?? "file") to Workstation…"
    }

    public func run(arguments: JSONValue, progress: @escaping @Sendable (String) -> Void) async throws -> ToolOutput {
        let rawName = try arguments.requiredString("name").trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanName = URL(fileURLWithPath: rawName).lastPathComponent
        guard !cleanName.isEmpty, cleanName != ".", cleanName != ".." else {
            throw ToolInputError("Provide a valid file name such as `preview.html` or `notes.md`.")
        }
        let content = try arguments.requiredString("content")
        let data = Data(content.utf8)
        let mime = arguments.optionalString("mime_type") ?? Self.inferMimeType(for: cleanName)
        let kind: AttachmentKind = mime.hasPrefix("image/") && mime != "image/svg+xml" ? .image : .text
        let reference = try await store.importWorkstationFile(data, name: cleanName, mimeType: mime, kind: kind)
        await onWritten(reference, content)
        return ToolOutput(
            forModel: "Saved `\(reference.name)` (\(Format.bytes(reference.bytes)), \(reference.mimeType)) to Workstation (`id: \(reference.id.uuidString)`).",
            summary: "Saved \(reference.name) to Workstation",
            detail: String(content.prefix(1_500))
        )
    }

    private static func inferMimeType(for filename: String) -> String {
        let ext = URL(fileURLWithPath: filename).pathExtension.lowercased()
        switch ext {
        case "html", "htm": return "text/html"
        case "mmd", "mermaid": return "text/vnd.mermaid"
        case "svg": return "image/svg+xml"
        case "md", "markdown": return "text/markdown"
        case "json": return "application/json"
        case "csv": return "text/csv"
        case "js", "mjs": return "text/javascript"
        case "ts", "tsx": return "text/typescript"
        case "css": return "text/css"
        case "py": return "text/x-python"
        case "swift": return "text/x-swift"
        case "sh": return "text/x-shellscript"
        case "xml": return "application/xml"
        case "yaml", "yml": return "text/yaml"
        default: return "text/plain"
        }
    }
}
