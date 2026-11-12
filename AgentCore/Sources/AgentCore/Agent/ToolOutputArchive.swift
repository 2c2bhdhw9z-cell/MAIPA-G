import Foundation

/// Keeps the whole of a tool result that is too long for the AI's context, the way Kiro does: the
/// AI sees the start and the end with a marker in the middle, and the marker says where the full
/// text is so the AI can read the cut part with `read_file` (`offset`/`limit`).
///
/// On the computer the runner saves to `~/.maipa-g/outputs/<callID>.txt`
/// (`DirectoryToolOutputSaver.computer(home:)`). The phone saves nothing until the app sets one
/// with `ToolOutputArchive.setDefault(_:)` or runs a turn inside
/// `ToolOutputArchive.$saver.withValue(_:)`.
public protocol ToolOutputSaver: Sendable {
    /// Saves the full text of one tool result. Returns the path the AI reads it back from (shown
    /// in the cut marker), or nil when it couldn't be saved.
    func save(_ text: String, callID: String, tool: String) -> String?
    /// The saved text behind a path `save` returned, or nil when `path` isn't one of this saver's.
    func savedText(at path: String) -> String?
    /// How the AI reads a saved output back, in the cut marker, e.g. "read it with read_file using offset/limit".
    var readHint: String { get }
}

public enum ToolOutputArchive {
    /// The saver for the turn running in this task (and every task it starts: tools, sub-agents).
    @TaskLocal public static var saver: (any ToolOutputSaver)? = nil

    private final class DefaultBox: @unchecked Sendable {
        let lock = NSLock()
        var value: (any ToolOutputSaver)?
    }
    private static let defaultBox = DefaultBox()

    /// A saver for every turn in this process that doesn't set its own (for the app: one place
    /// at start-up instead of around every run).
    public static func setDefault(_ saver: (any ToolOutputSaver)?) {
        defaultBox.lock.withLock { defaultBox.value = saver }
    }

    /// The saver in effect here: this task's, else the process default, else none.
    public static var current: (any ToolOutputSaver)? {
        if let saver { return saver }
        return defaultBox.lock.withLock { defaultBox.value }
    }

    /// `<callID>.txt` with only file-name-safe characters. Short or empty ids get a random suffix
    /// so two calls never share a file.
    static func fileName(for callID: String) -> String {
        let safe = String(callID.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) && $0.isASCII || $0 == "_" || $0 == "-" }.prefix(120).map(Character.init))
        if safe.count >= 6 { return safe + ".txt" }
        let suffix = UUID().uuidString.prefix(8).lowercased()
        return (safe.isEmpty ? "output" : safe) + "-" + suffix + ".txt"
    }
}

/// Saves full tool outputs as text files in one folder.
public struct DirectoryToolOutputSaver: ToolOutputSaver {
    public let directory: URL
    /// How paths are written for the AI, e.g. `~/.maipa-g/outputs`.
    public let displayPrefix: String
    public let readHint: String
    /// Oldest files are removed beyond this many, so the folder never grows without end.
    public let keep: Int

    public init(directory: URL, displayPrefix: String = "~/.maipa-g/outputs", readHint: String = "read it with read_file using offset/limit", keep: Int = 300) {
        self.directory = directory
        self.displayPrefix = displayPrefix.hasSuffix("/") ? String(displayPrefix.dropLast()) : displayPrefix
        self.readHint = readHint
        self.keep = max(1, keep)
    }

    /// `~/.maipa-g/outputs` in `home`, for the runner on the person's computer. The file is on
    /// disk there, so commands can read it too.
    public static func computer(home: URL) -> DirectoryToolOutputSaver {
        DirectoryToolOutputSaver(
            directory: home.appendingPathComponent(".maipa-g/outputs", isDirectory: true),
            displayPrefix: "~/.maipa-g/outputs",
            readHint: "read it with read_file using offset/limit (or with run_command, e.g. sed -n '1,200p' on that path)"
        )
    }

    public func save(_ text: String, callID: String, tool: String) -> String? {
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            let name = ToolOutputArchive.fileName(for: callID)
            let file = directory.appendingPathComponent(name)
            try Data(text.utf8).write(to: file, options: .atomic)
            try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            prune(keeping: name)
            return "\(displayPrefix)/\(name)"
        } catch {
            return nil
        }
    }

    public func savedText(at path: String) -> String? {
        guard let name = fileName(in: path) else { return nil }
        let file = directory.appendingPathComponent(name)
        guard let data = FileManager.default.contents(atPath: file.path) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Whether `path` names a file in this saver's folder (written with the display prefix, the
    /// real folder, or `$HOME`).
    public func owns(_ path: String) -> Bool { fileName(in: path) != nil }

    private func fileName(in rawPath: String) -> String? {
        let path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        var candidates = [displayPrefix + "/", directory.standardizedFileURL.path + "/"]
        if displayPrefix.hasPrefix("~/") {
            candidates.append("$HOME/" + displayPrefix.dropFirst(2) + "/")
            candidates.append(String(displayPrefix.dropFirst(2)) + "/")
        }
        for prefix in candidates where path.hasPrefix(prefix) {
            let name = String(path.dropFirst(prefix.count))
            guard !name.isEmpty, !name.contains("/"), name != ".", name != "..",
                  name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }) else { return nil }
            return name
        }
        return nil
    }

    /// Removes the oldest files beyond `keep`, never the one just written.
    private func prune(keeping newest: String) {
        let manager = FileManager.default
        guard let files = try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]),
              files.count > keep else { return }
        let older = files.filter { $0.lastPathComponent != newest }
        let dated: [(url: URL, date: Date)] = older.map { url in
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date.distantPast
            return (url, date)
        }
        let oldestFirst = dated.sorted { (a: (url: URL, date: Date), b: (url: URL, date: Date)) -> Bool in
            if a.date != b.date { return a.date < b.date }
            return a.url.lastPathComponent < b.url.lastPathComponent
        }
        for item in oldestFirst.prefix(files.count - keep) { try? manager.removeItem(at: item.url) }
    }
}
