import Foundation

// MARK: Files from the computer

extension ComputerControl {
    /// Reads `~/<path>` from the computer in base64 pieces. A piece that comes back short (a
    /// service that caps how much one command may print) makes the pieces smaller and that piece
    /// is read again.
    public func readFile(homePath path: String, maxBytes: Int = 25 * 1024 * 1024) async throws -> Data {
        // Any name a file can have, quoted for the shell: "Signer build 38.ipa" was refused for its
        // spaces, so the IPA never reached the phone (owner, 15 November 2026: "IPA didn't come through").
        guard Self.isSafeHomePath(path) else { throw Failure.commandFailed("Unsafe file path \(path)") }
        let file = "\"$HOME\"/" + Self.shellQuote(path)
        let sizeOutput = Self.plainOutput(try await run("if [ -f \(file) ]; then echo \"maipa-g-size: $(wc -c < \(file) | tr -d ' ')\"; else echo maipa-g-missing; fi"))
        guard let size = Self.note("maipa-g-size", in: sizeOutput).flatMap(Int.init) else {
            throw Failure.commandFailed("There's no file at ~/\(path) on the computer.")
        }
        guard size <= maxBytes else { throw Failure.commandFailed("~/\(path) is \(size / 1_048_576) MB, more than MAIPA-G brings back (\(maxBytes / 1_048_576) MB).") }
        var data = Data()
        var piece = commandSizeLimit == nil ? 60_000 : 393_216
        while data.count < size {
            let want = min(piece, size - data.count)
            let output = Self.plainOutput(try await run("echo \"maipa-g-data: $(tail -c +\(data.count + 1) \(file) | head -c \(want) | base64 | tr -d '\\n')\""))
            let decoded = Self.note("maipa-g-data", in: output).flatMap { Data(base64Encoded: $0) }
            if let decoded, decoded.count == want {
                data.append(decoded)
            } else if piece > 24_000 {
                piece /= 2
            } else {
                throw Failure.commandFailed("Couldn't read ~/\(path) back from the computer.")
            }
        }
        return data
    }
}

// MARK: Pictures between the chat and the computer

/// Puts a chat picture on the computer, for exact work with ImageMagick or Python there.
public struct CopyPictureToComputerTool: AgentTool {
    public let name = "copy_picture_to_computer"
    let control: ComputerControl
    let store: AttachmentStore
    let pictures: [AttachmentReference]

    public init(control: ComputerControl, store: AttachmentStore, pictures: [AttachmentReference]) {
        self.control = control
        self.store = store
        self.pictures = pictures.filter { $0.kind == .image }
    }

    public var spec: ToolSpec {
        ToolSpec(name: name, description: "Copy a picture from this chat onto the chat computer, into ~/pictures/, for exact edits there (ImageMagick, Python with Pillow, rembg for backgrounds, OpenCV for upscaling). Bring the result back with show_computer_picture.", parameters: [
            "type": "object",
            "properties": ["picture": ["type": "string", "enum": .array(pictures.map { .string($0.name) })]],
            "required": ["picture"],
            "additionalProperties": false,
        ])
    }

    public func runningSummary(for arguments: JSONValue) -> String { "Putting the picture on the computer…" }

    static func safeName(_ name: String) -> String {
        let cleaned = name.map { $0.isLetter || $0.isNumber || "._-".contains($0) ? $0 : "-" }
        let text = String(cleaned).trimmingCharacters(in: CharacterSet(charactersIn: ".-"))
        return text.isEmpty ? "picture.png" : String(text.prefix(80))
    }

    public func run(arguments: JSONValue, progress: @escaping @Sendable (String) -> Void) async throws -> ToolOutput {
        let wanted = try arguments.requiredString("picture")
        guard let picture = pictures.first(where: { $0.name == wanted || $0.id.uuidString.lowercased() == wanted.lowercased() }) else {
            throw ToolInputError("There is no picture called \(wanted) in this chat. Pictures here: \(pictures.map(\.name).joined(separator: ", ")).")
        }
        let path = "pictures/\(Self.safeName(picture.name))"
        try await control.writeFile(try await store.data(for: picture), toHomePath: path)
        return ToolOutput(forModel: "Copied \(picture.name) to ~/\(path) on \(control.machine).", summary: "Put \(picture.name) on the computer")
    }
}

/// Files under `~/attachments/` come from every chat the person has: only this chat's are this
/// chat's (owner, 15 November 2026: "Why are screenshots I never sent this chat in this chat").
/// The Korg reply found the newest photo there, a screenshot sent to his emulator chat, and showed
/// it twice while trying to read it itself.
enum ChatFilesOnComputer {
    /// A home path the reply may open, or why not.
    static func refusal(for path: String, chatFiles: [AttachmentReference]) -> String? {
        guard path.hasPrefix("attachments/") else { return nil }
        let own = Set(chatFiles.map(ComputerControl.attachmentHomePath))
        if own.contains(path) { return nil }
        return "~/\(path) was attached in another of the person's chats, not this one, so it isn't this chat's to open or show. Work only with this chat's files (listed in your instructions); if you need a screenshot, ask the person to send it here."
    }

    static func homePath(_ raw: String) -> String {
        var path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["~/", "$HOME/", "/home/sprite/"] where path.hasPrefix(prefix) { path.removeFirst(prefix.count) }
        return path
    }
}

/// Lets the AI look at a picture on the computer itself (a screenshot it was sent, a frame a test
/// rendered), the way Kiro's read_file returns pictures. Nothing goes into the chat. Before this the
/// only way was show_computer_picture, which puts the picture in front of the person.
public struct ViewComputerPictureTool: AgentTool {
    public static let toolName = "view_computer_picture"
    public let name = ViewComputerPictureTool.toolName
    let control: ComputerControl
    let chatFiles: [AttachmentReference]
    static let maxBytes = 10 * 1024 * 1024

    public init(control: ComputerControl, chatFiles: [AttachmentReference] = []) {
        self.control = control
        self.chatFiles = chatFiles
    }

    public var spec: ToolSpec {
        ToolSpec(name: name, description: "Look at a picture file on the chat computer yourself (PNG, JPEG, WebP or GIF, up to 10 MB): a screenshot from this chat, a frame a test rendered, a chart. It comes back to you as an image; nothing is put in the chat. To give the person a picture, use show_computer_picture instead.", parameters: [
            "type": "object",
            "properties": [
                "path": ["type": "string", "description": "Path inside the home folder, such as pictures/frame.png."],
            ],
            "required": ["path"],
            "additionalProperties": false,
        ])
    }

    public func runningSummary(for arguments: JSONValue) -> String { "Looking at the picture…" }

    public func run(arguments: JSONValue, progress: @escaping @Sendable (String) -> Void) async throws -> ToolOutput {
        let path = ChatFilesOnComputer.homePath(try arguments.requiredString("path"))
        guard ComputerControl.isSafeHomePath(path) else { throw ToolInputError("Give a path inside the home folder, such as pictures/frame.png.") }
        if let refusal = ChatFilesOnComputer.refusal(for: path, chatFiles: chatFiles) { throw ToolInputError(refusal) }
        guard let mime = ShowComputerPictureTool.mimeType(for: path) else { throw ToolInputError("Only PNG, JPEG, WebP and GIF pictures can be looked at this way. Convert it first (for example with ImageMagick's convert).") }
        let data = try await control.readFile(homePath: path, maxBytes: Self.maxBytes)
        let name = (path as NSString).lastPathComponent
        return ToolOutput(
            forModel: "Here is ~/\(path) (\(Format.bytes(data.count))). Only you see it; it isn't in the chat.",
            summary: "Looked at \(name)",
            inlineImages: [ToolInlineImage(name: name, mimeType: mime, data: data)]
        )
    }
}

/// Brings a picture made or changed on the computer into the chat, saved with it.
public struct ShowComputerPictureTool: AgentTool {
    public let name = "show_computer_picture"
    let control: ComputerControl
    let store: AttachmentStore
    let chatFiles: [AttachmentReference]

    public init(control: ComputerControl, store: AttachmentStore, chatFiles: [AttachmentReference] = []) {
        self.control = control
        self.store = store
        self.chatFiles = chatFiles
    }

    public var spec: ToolSpec {
        ToolSpec(name: name, description: "Show a picture file from the chat computer (PNG, JPEG, WebP or GIF) in the chat and save it with the chat, so the person can see, save, share or keep changing it. Only for a picture you made or changed for the person, or one they asked to see. Never to look at a picture yourself: that's view_computer_picture.", parameters: [
            "type": "object",
            "properties": [
                "path": ["type": "string", "description": "Path inside the home folder, such as pictures/result.png."],
                "description": ["type": "string", "description": "One line on what the picture is."],
            ],
            "required": ["path"],
            "additionalProperties": false,
        ])
    }

    public func runningSummary(for arguments: JSONValue) -> String { "Bringing the picture into the chat…" }

    static func mimeType(for path: String) -> String? {
        switch (path as NSString).pathExtension.lowercased() {
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "webp": "image/webp"
        case "gif": "image/gif"
        default: nil
        }
    }

    public func run(arguments: JSONValue, progress: @escaping @Sendable (String) -> Void) async throws -> ToolOutput {
        let path = ChatFilesOnComputer.homePath(try arguments.requiredString("path"))
        guard ComputerControl.isSafeHomePath(path) else { throw ToolInputError("Give a path inside the home folder, such as pictures/result.png.") }
        if let refusal = ChatFilesOnComputer.refusal(for: path, chatFiles: chatFiles) { throw ToolInputError(refusal) }
        guard let mime = Self.mimeType(for: path) else { throw ToolInputError("Only PNG, JPEG, WebP and GIF pictures can be shown in the chat.") }
        let data = try await control.readFile(homePath: path)
        let ext = (path as NSString).pathExtension.lowercased()
        let reference = try await store.importGeneratedImage(data, name: "picture-\(UUID().uuidString.lowercased()).\(ext)", mimeType: mime)
        let result = GeneratedImageResult(attachment: reference, prompt: arguments.optionalString("description") ?? "Made on \(control.machine): \(path)", model: control.machine, aspectRatio: "", quality: "")
        try await store.saveGeneratedMetadata(result)
        return ToolOutput(forModel: "Showed ~/\(path) in the chat as \(reference.name).", summary: "Showed \((path as NSString).lastPathComponent)", generatedImages: [result])
    }
}
