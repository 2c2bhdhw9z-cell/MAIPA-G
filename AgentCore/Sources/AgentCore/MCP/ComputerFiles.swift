import Foundation

/// Gives the chat computer a short-lived HTTPS address to download one chat file from. The phone
/// makes it: the file goes up once to MAIPA-G-data's private files release, and GitHub hands back
/// a storage address that works for a few minutes without any token.
public typealias ChatFileLink = @Sendable (AttachmentReference) async throws -> URL

// MARK: Chat files onto the computer, as the real files

extension ComputerControl {
    /// Where a chat file goes on the computer: `~/attachments/<first 8 of its id>/<its name>`.
    public static func attachmentHomePath(_ attachment: AttachmentReference) -> String {
        "attachments/\(attachment.id.uuidString.prefix(8).lowercased())/\(CopyPictureToComputerTool.safeName(attachment.name))"
    }

    /// The paths among `files` that are already on the computer with exactly that many bytes.
    public func filesPresent(_ files: [(path: String, bytes: Int)]) async throws -> Set<String> {
        let safe = files.filter { Self.isSafeRelativePath($0.path) }
        guard !safe.isEmpty else { return [] }
        let checks = safe.map { file in
            "[ \"$(wc -c < \"$HOME/\(file.path)\" 2>/dev/null | tr -d ' ')\" = \"\(file.bytes)\" ] && echo 'maipa-g-has: \(file.path)'"
        }
        let output = Self.plainOutput(try await run((checks + ["true"]).joined(separator: "; ")))
        return Set(output.components(separatedBy: "\n").compactMap { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("maipa-g-has: ") else { return nil }
            return String(trimmed.dropFirst("maipa-g-has: ".count))
        })
    }

    /// The computer downloads `url` straight to `~/<path>`; the size is checked before the file
    /// is put in place, so a cut-off download never looks like the file.
    public func download(_ url: URL, toHomePath path: String, bytes: Int) async throws {
        guard Self.isSafeRelativePath(path) else { throw Failure.commandFailed("Unsafe file path \(path)") }
        let address = url.absoluteString
        guard url.scheme == "https", !address.contains("'"), !address.contains(where: \.isNewline) else {
            throw Failure.commandFailed("MAIPA-G can't use that download address.")
        }
        let script = """
        set -u
        umask 077
        f="$HOME/\(path)"
        mkdir -p "$(dirname "$f")"
        curl -fsSL --retry 3 --connect-timeout 20 -o "$f.part" '\(address)' 2>&1 | tail -n 3
        s=$(wc -c < "$f.part" 2>/dev/null | tr -d ' ')
        if [ "$s" = "\(bytes)" ]; then mv -f "$f.part" "$f"; echo maipa-g-download-ok; else rm -f "$f.part"; echo "maipa-g-download-short: ${s:-0} of \(bytes) bytes"; fi
        """
        let output = Self.plainOutput(try await run(script, timeout: 900))
        guard output.contains("maipa-g-download-ok") else {
            throw Failure.commandFailed("The computer couldn't download it: \(String(output.suffix(300)))")
        }
    }

    /// Puts one chat file on the computer unless it's already there, and returns its path under ~.
    public func put(_ attachment: AttachmentReference, link: ChatFileLink) async throws -> String {
        let path = Self.attachmentHomePath(attachment)
        if try await filesPresent([(path, attachment.bytes)]).contains(path) { return path }
        try await download(try await link(attachment), toHomePath: path, bytes: attachment.bytes)
        return path
    }
}

/// Puts any file from the chat (an app, an archive, a document, a picture) on the chat computer
/// as the real file, so commands can unpack, inspect, change or rebuild it.
public struct CopyFileToComputerTool: AgentTool {
    public let name = "copy_file_to_computer"
    let control: ComputerControl
    let files: [AttachmentReference]
    let link: ChatFileLink

    public init(control: ComputerControl, files: [AttachmentReference], link: @escaping ChatFileLink) {
        self.control = control
        self.files = files
        self.link = link
    }

    private var names: [String] {
        var seen = Set<String>()
        return files.compactMap { seen.insert($0.name).inserted ? $0.name : nil }
    }

    public var spec: ToolSpec {
        ToolSpec(name: name, description: "Put a file from this chat (any kind: .ipa, .apk, .zip and other archives, documents, pictures, up to 250 MB) on the chat computer as the real file, under ~/attachments/. Use it whenever a command needs the file itself: to unpack, inspect, change or rebuild it. Returns the file's path there; then work on it with run_command.", parameters: [
            "type": "object",
            "properties": ["file": ["type": "string", "enum": .array(names.map { .string($0) })]],
            "required": ["file"],
            "additionalProperties": false,
        ])
    }

    public func runningSummary(for arguments: JSONValue) -> String {
        "Putting \(arguments["file"]?.stringValue ?? "the file") on the computer…"
    }

    public func run(arguments: JSONValue, progress: @escaping @Sendable (String) -> Void) async throws -> ToolOutput {
        let wanted = try arguments.requiredString("file")
        guard let file = files.last(where: { $0.name == wanted || $0.id.uuidString.lowercased() == wanted.lowercased() }) else {
            throw ToolInputError("There is no file called \(wanted) in this chat. Files here: \(names.joined(separator: ", ")).")
        }
        let path = try await control.put(file, link: link)
        return ToolOutput(forModel: "\(file.name) (\(file.bytes) bytes) is at ~/\(path) on \(control.machine). Work on it there with run_command.", summary: "Put \(file.name) on the computer")
    }
}
