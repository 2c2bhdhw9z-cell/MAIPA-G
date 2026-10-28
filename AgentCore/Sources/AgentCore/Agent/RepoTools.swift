import Foundation

/// What reading one file gave.
public enum FileRead: Sendable, Hashable {
    case text(String, bytes: Int)
    case binary(bytes: Int)
    case tooLarge(bytes: Int)
    case folder
    case symlink(target: String)
    case missing(suggestions: [String])
}

/// A repo at one commit, as the AI's tools see it. All tools in one answer share one workspace, so
/// they all see the same version of every file even if someone pushes in the meantime.
///
/// Listing uses GitHub's tree API (one quick request); reading uses the local copy when it is
/// ready and fetches single files otherwise; searching needs the local copy and makes it on first
/// use (it is usually ready, because it starts downloading when the chat begins).
public actor RepoWorkspace {
    public let repo: RepoRef
    public let branch: String
    public let commit: String
    private let github: GitHubClient
    private let store: SnapshotStore
    private var treeTask: Task<GitTree, Error>?
    private var snapshotTask: Task<RepoSnapshot, Error>?
    private var snapshot: RepoSnapshot?
    private var fileCache: [String: Data] = [:]
    private var listeners: [UUID: @Sendable (SnapshotProgress) -> Void] = [:]

    public init(repo: RepoRef, branch: String, commit: String, github: GitHubClient, store: SnapshotStore) {
        self.repo = repo
        self.branch = branch
        self.commit = commit
        self.github = github
        self.store = store
    }

    public var shortCommit: String { String(commit.prefix(7)) }

    /// Every file and folder at this commit.
    public func tree() async throws -> GitTree {
        if let running = treeTask { return try await running.value }
        let github = github, repo = repo, commit = commit
        let task = Task { try await github.tree(repo, sha: commit, recursive: true) }
        treeTask = task
        do {
            var tree = try await task.value
            if tree.truncated {
                // Over 100,000 entries: GitHub's listing stops short, so list the local copy instead.
                let copy = try await localCopy(progress: { _ in })
                tree = GitTree(sha: commit, entries: copy.manifest.files.map {
                    GitTreeEntry(path: $0.path, mode: $0.kind == .symlink ? "120000" : "100644", type: "blob", sha: "", size: $0.size)
                } + Self.folders(of: copy.manifest.files.map(\.path)), truncated: false)
                let complete = tree
                treeTask = Task { complete }
            }
            return tree
        } catch {
            treeTask = nil
            throw error
        }
    }

    static func folders(of paths: [String]) -> [GitTreeEntry] {
        var folders = Set<String>()
        for path in paths {
            var parts = path.split(separator: "/").dropLast()
            while !parts.isEmpty {
                folders.insert(parts.joined(separator: "/"))
                parts = parts.dropLast()
            }
        }
        return folders.sorted().map { GitTreeEntry(path: $0, mode: "040000", type: "tree", sha: "") }
    }

    /// Starts making the local copy in the background, so a search later is instant.
    public func prefetch() {
        _ = startCopy()
    }

    private func startCopy() -> Task<RepoSnapshot, Error> {
        if let snapshotTask { return snapshotTask }
        let store = store, github = github, repo = repo, commit = commit
        // The task holds the workspace until the copy is made, which is what keeps progress
        // reaching whoever is waiting on it.
        let workspace = self
        let task = Task<RepoSnapshot, Error> {
            try await store.snapshot(repo, commit: commit, github: github) { progress in
                Task { await workspace.broadcast(progress) }
            }
        }
        snapshotTask = task
        return task
    }

    private func broadcast(_ progress: SnapshotProgress) {
        for listener in listeners.values { listener(progress) }
    }

    /// The local copy, made now if needed. `progress` hears how the download is going.
    public func localCopy(progress: @escaping @Sendable (SnapshotProgress) -> Void) async throws -> RepoSnapshot {
        if let snapshot { return snapshot }
        if let cached = await store.cachedSnapshot(repo, commit: commit) {
            snapshot = cached
            return cached
        }
        let id = UUID()
        listeners[id] = progress
        defer { listeners[id] = nil }
        do {
            let copy = try await startCopy().value
            snapshot = copy
            return copy
        } catch {
            snapshotTask = nil
            throw error
        }
    }

    public func readFile(_ rawPath: String) async throws -> FileRead {
        let path = Self.normalize(rawPath)
        if let snapshot, let file = snapshot.file(path) {
            switch file.kind {
            case .text:
                let data = snapshot.contents(of: path) ?? Data()
                return .text(String(decoding: data, as: UTF8.self), bytes: data.count)
            case .binary: return .binary(bytes: file.size)
            case .tooLarge: return .tooLarge(bytes: file.size)
            case .symlink: return .symlink(target: file.linkTarget ?? "")
            }
        }
        let tree = try await tree()
        guard let entry = tree.entries.first(where: { $0.path == path }) else {
            if path.isEmpty { return .folder }
            return .missing(suggestions: Self.suggestions(for: path, in: tree))
        }
        if entry.isFolder { return .folder }
        if entry.isSymlink {
            let target = try await github.blob(repo, sha: entry.sha)
            return .symlink(target: String(decoding: target, as: UTF8.self))
        }
        let size = entry.size ?? 0
        if size > SnapshotStore.maxStoredFileSize { return .tooLarge(bytes: size) }
        let data: Data
        if let cached = fileCache[path] {
            data = cached
        } else {
            data = try await github.blob(repo, sha: entry.sha)
            fileCache[path] = data
        }
        if data.prefix(SnapshotStore.binarySniffLength).contains(0) { return .binary(bytes: data.count) }
        return .text(String(decoding: data, as: UTF8.self), bytes: data.count)
    }

    static func normalize(_ path: String) -> String {
        var path = path.trimmingCharacters(in: .whitespacesAndNewlines)
        while path.hasPrefix("./") { path.removeFirst(2) }
        while path.hasPrefix("/") { path.removeFirst() }
        while path.hasSuffix("/") { path.removeLast() }
        return path
    }

    /// Paths that look like what the AI meant, for when it gets one slightly wrong.
    static func suggestions(for path: String, in tree: GitTree) -> [String] {
        let name = path.split(separator: "/").last.map(String.init)?.lowercased() ?? path.lowercased()
        let files = tree.entries.filter(\.isFile).map(\.path)
        let sameName = files.filter { $0.split(separator: "/").last.map(String.init)?.lowercased() == name }
        if !sameName.isEmpty { return Array(sameName.prefix(5)) }
        let containing = files.filter { $0.lowercased().contains(name) }
        return Array(containing.prefix(5))
    }
}

enum Format {
    static func bytes(_ count: Int) -> String {
        if count < 1024 { return "\(count) B" }
        let kb = Double(count) / 1024
        if kb < 1024 { return String(format: kb < 10 ? "%.1f KB" : "%.0f KB", kb) }
        let mb = kb / 1024
        if mb < 1024 { return String(format: mb < 10 ? "%.1f MB" : "%.0f MB", mb) }
        return String(format: "%.1f GB", mb / 1024)
    }

    static func lastComponent(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    static func quote(_ text: String, limit: Int = 40) -> String {
        let short = text.count > limit ? String(text.prefix(limit)) + "…" : text
        return "“\(short)”"
    }
}

// MARK: - list_files

public struct ListFilesTool: AgentTool {
    public let workspace: RepoWorkspace
    public let name = "list_files"
    static let maxLines = 400

    public init(workspace: RepoWorkspace) {
        self.workspace = workspace
    }

    public var spec: ToolSpec {
        ToolSpec(
            name: name,
            description: """
            List the files and folders in the repository. Give a folder to look inside it, and a depth to \
            see deeper. Give a pattern (like "*.swift" or "src/**/*.ts") to find files by name anywhere.
            """,
            parameters: [
                "type": "object",
                "properties": [
                    "path": ["type": "string", "description": "Folder to list. Leave empty for the top of the repository."],
                    "depth": ["type": "integer", "minimum": 1, "maximum": 8, "description": "How many folder levels to show. Default 2."],
                    "pattern": ["type": "string", "description": "Optional file-name pattern, such as \"*.md\" or \"App/**/*.swift\"."],
                ],
            ]
        )
    }

    public func runningSummary(for arguments: JSONValue) -> String {
        if let pattern = arguments.optionalString("pattern") { return "Looking for \(Format.quote(pattern))…" }
        if let path = arguments.optionalString("path").map(RepoWorkspace.normalize), !path.isEmpty { return "Looking in \(path)…" }
        return "Looking through the repo…"
    }

    public func run(arguments: JSONValue, progress: @escaping @Sendable (String) -> Void) async throws -> ToolOutput {
        let folder = RepoWorkspace.normalize(arguments.optionalString("path") ?? "")
        let depth = min(max(arguments.optionalInt("depth") ?? 2, 1), 8)
        let tree = try await workspace.tree()
        let prefix = folder.isEmpty ? "" : folder + "/"
        let inside = tree.entries.filter { folder.isEmpty || $0.path.hasPrefix(prefix) }

        if !folder.isEmpty, inside.isEmpty {
            if tree.entries.contains(where: { $0.path == folder && $0.isFile }) {
                throw ToolInputError("\(folder) is a file, not a folder. Use read_file to read it.")
            }
            let suggestions = RepoWorkspace.suggestions(for: folder, in: tree)
            throw ToolInputError("There is no folder \(folder)." + (suggestions.isEmpty ? "" : " Did you mean: " + suggestions.joined(separator: ", ") + "?"))
        }

        if let pattern = arguments.optionalString("pattern") {
            let glob = Glob(pattern)
            let matches = inside.filter { $0.isFile && glob.matches($0.path) }
            var lines = ["Files matching \(pattern)" + (folder.isEmpty ? "" : " in \(folder)") + " (\(matches.count)):"]
            for entry in matches.prefix(Self.maxLines) {
                lines.append("\(entry.path)  \(Format.bytes(entry.size ?? 0))")
            }
            if matches.count > Self.maxLines { lines.append("…and \(matches.count - Self.maxLines) more. Use a narrower pattern or folder.") }
            if matches.isEmpty { lines.append("(none)") }
            return ToolOutput(
                forModel: lines.joined(separator: "\n"),
                summary: matches.isEmpty ? "Looked for \(Format.quote(pattern)) · none found" : "Found \(matches.count) file\(matches.count == 1 ? "" : "s") matching \(Format.quote(pattern))",
                detail: lines.dropFirst().prefix(60).joined(separator: "\n")
            )
        }

        // Count the files under every folder once, for the "(12 files)" notes.
        var counts: [String: Int] = [:]
        var children: [String: [GitTreeEntry]] = [:]
        for entry in inside {
            let parent = entry.path.split(separator: "/").dropLast().joined(separator: "/")
            children[parent, default: []].append(entry)
            if entry.isFile {
                var parts = entry.path.split(separator: "/").dropLast()
                while !parts.isEmpty {
                    counts[parts.joined(separator: "/"), default: 0] += 1
                    parts = parts.dropLast()
                }
            }
        }
        let totalFiles = inside.filter(\.isFile).count
        var lines = [(folder.isEmpty ? "\(workspace.repo.fullName) at \(await workspace.shortCommit)" : folder) + " (\(totalFiles) files)"]
        var truncated = false

        func walk(_ parent: String, level: Int) {
            let items = (children[parent] ?? []).sorted { a, b in
                if a.isFolder != b.isFolder { return a.isFolder }
                return a.path.localizedStandardCompare(b.path) == .orderedAscending
            }
            for item in items {
                if lines.count >= Self.maxLines {
                    truncated = true
                    return
                }
                let indent = String(repeating: "  ", count: level)
                let name = Format.lastComponent(item.path)
                if item.isFolder {
                    lines.append("\(indent)\(name)/  (\(counts[item.path] ?? 0) files)")
                    if level + 1 < depth { walk(item.path, level: level + 1) }
                } else if item.type == "commit" {
                    lines.append("\(indent)\(name)  (submodule)")
                } else {
                    lines.append("\(indent)\(name)  \(Format.bytes(item.size ?? 0))")
                }
            }
        }
        walk(folder, level: 0)
        if truncated { lines.append("…list cut short. Look inside one folder at a time, or use a pattern.") }
        return ToolOutput(
            forModel: lines.joined(separator: "\n"),
            summary: folder.isEmpty ? "Looked through the repo" : "Looked in \(folder)",
            detail: lines.prefix(80).joined(separator: "\n")
        )
    }
}

// MARK: - read_file

public struct ReadFileTool: AgentTool {
    public let workspace: RepoWorkspace
    public let name = "read_file"
    static let maxLines = 600
    static let maxCharacters = 60_000
    static let maxLineLength = 1_000

    public init(workspace: RepoWorkspace) {
        self.workspace = workspace
    }

    public var spec: ToolSpec {
        ToolSpec(
            name: name,
            description: """
            Read a text file from the repository, with line numbers. Long files come back in parts: \
            use start_line and end_line to read a part, or to keep reading.
            """,
            parameters: [
                "type": "object",
                "properties": [
                    "path": ["type": "string", "description": "Path from the top of the repository, like \"App/Sources/Main.swift\"."],
                    "start_line": ["type": "integer", "minimum": 1, "description": "First line to read. Default 1."],
                    "end_line": ["type": "integer", "minimum": 1, "description": "Last line to read."],
                ],
                "required": ["path"],
            ]
        )
    }

    public func runningSummary(for arguments: JSONValue) -> String {
        "Reading \(Format.lastComponent(arguments.optionalString("path") ?? "a file"))…"
    }

    public func run(arguments: JSONValue, progress: @escaping @Sendable (String) -> Void) async throws -> ToolOutput {
        let path = RepoWorkspace.normalize(try arguments.requiredString("path"))
        switch try await workspace.readFile(path) {
        case .missing(let suggestions):
            throw ToolInputError("There is no file \(path)." + (suggestions.isEmpty ? " Use list_files or search_code to find it." : " Did you mean: " + suggestions.joined(separator: ", ") + "?"))
        case .folder:
            throw ToolInputError("\(path.isEmpty ? "That" : path) is a folder. Use list_files to see what is in it.")
        case .binary(let bytes):
            return ToolOutput(forModel: "\(path) is a binary file (\(Format.bytes(bytes))), such as a picture or an archive. It can't be shown as text.", summary: "Looked at \(path) · not text")
        case .tooLarge(let bytes):
            return ToolOutput(forModel: "\(path) is too large to read (\(Format.bytes(bytes))). Use search_code to find the part you need.", summary: "Looked at \(path) · too large")
        case .symlink(let target):
            return ToolOutput(forModel: "\(path) is a link to \(target).", summary: "Looked at \(path) · a link")
        case .text(let text, let bytes):
            var lines: [Substring] = text.split(separator: "\n", omittingEmptySubsequences: false)
            if lines.last == "" { lines.removeLast() }
            let total = lines.count
            if total == 0 {
                return ToolOutput(forModel: "\(path) is empty.", summary: "Read \(path) · empty")
            }
            let start = min(max(arguments.optionalInt("start_line") ?? 1, 1), total)
            let requestedEnd = arguments.optionalInt("end_line").map { max($0, start) } ?? total
            var end = min(requestedEnd, total, start + Self.maxLines - 1)
            var body: [String] = []
            var characters = 0
            for number in start...end {
                var line = String(lines[number - 1])
                if line.hasSuffix("\r") { line.removeLast() }
                if line.count > Self.maxLineLength { line = String(line.prefix(Self.maxLineLength)) + "…" }
                let numbered = String(repeating: " ", count: max(0, 6 - String(number).count)) + "\(number)\t" + line
                if characters + numbered.count > Self.maxCharacters, !body.isEmpty {
                    end = number - 1
                    break
                }
                characters += numbered.count + 1
                body.append(numbered)
            }
            let isWhole = start == 1 && end == total
            var header = "\(path) (\(Format.bytes(bytes)), \(total) lines)"
            if !isWhole { header += ", showing lines \(start)-\(end)" }
            var output = header + "\n" + body.joined(separator: "\n")
            if end < total, end < requestedEnd || arguments.optionalInt("end_line") == nil {
                output += "\n(\(total - end) more lines. Read on with start_line \(end + 1).)"
            }
            return ToolOutput(
                forModel: output,
                summary: isWhole ? "Read \(path)" : "Read \(path) · lines \(start)–\(end)",
                detail: body.prefix(40).joined(separator: "\n")
            )
        }
    }
}

// MARK: - search_code

public struct SearchCodeTool: AgentTool {
    public let workspace: RepoWorkspace
    public let name = "search_code"

    public init(workspace: RepoWorkspace) {
        self.workspace = workspace
    }

    public var spec: ToolSpec {
        ToolSpec(
            name: name,
            description: """
            Search every text file in the repository for some text, or for a regular expression, and get \
            each matching line with its file and line number. Narrow it with path_glob, like "*.swift" or \
            "docs/**".
            """,
            parameters: [
                "type": "object",
                "properties": [
                    "query": ["type": "string", "description": "The text to find (or the regular expression, if regex is true)."],
                    "regex": ["type": "boolean", "description": "Treat query as a regular expression. Default false."],
                    "case_sensitive": ["type": "boolean", "description": "Match upper and lower case exactly. Default false."],
                    "path_glob": ["type": "string", "description": "Only search files whose path matches this pattern."],
                    "max_results": ["type": "integer", "minimum": 1, "maximum": 200, "description": "Most matching lines to return. Default 80."],
                ],
                "required": ["query"],
            ]
        )
    }

    public func runningSummary(for arguments: JSONValue) -> String {
        "Searching for \(Format.quote(arguments.optionalString("query") ?? ""))…"
    }

    public func run(arguments: JSONValue, progress: @escaping @Sendable (String) -> Void) async throws -> ToolOutput {
        let query = SearchQuery(
            pattern: try arguments.requiredString("query"),
            isRegex: arguments.optionalBool("regex") ?? false,
            caseSensitive: arguments.optionalBool("case_sensitive") ?? false,
            pathGlob: arguments.optionalString("path_glob"),
            maxResults: min(max(arguments.optionalInt("max_results") ?? 80, 1), 200)
        )
        let copy = try await workspace.localCopy { update in
            switch update {
            case .downloading(let bytes): progress("Getting a copy of the repo to search · \(Format.bytes(Int(bytes)))")
            case .unpacking(let files): progress("Unpacking the copy · \(files) files")
            case .updating(let changed): progress("Updating the copy · \(changed) changed file\(changed == 1 ? "" : "s")")
            }
        }
        let result: SearchResult
        do {
            result = try await CodeSearch.run(query, in: copy)
        } catch let error as SearchError {
            throw ToolInputError(error.description)
        }
        let described = Format.quote(query.pattern, limit: 60)
        guard !result.matches.isEmpty else {
            var text = "No matches for \(query.pattern) in \(result.filesSearched) files"
            if let glob = query.pathGlob { text += " matching \(glob)" }
            text += "."
            if result.filesSkipped > 0 { text += " (\(result.filesSkipped) files are pictures, archives or too large to search.)" }
            return ToolOutput(forModel: text, summary: "Searched for \(described) · no matches")
        }
        var lines = ["\(result.matches.count)\(result.truncated ? "+" : "") matching lines in \(result.filesMatched) file\(result.filesMatched == 1 ? "" : "s") for \(query.pattern)\(query.isRegex ? " (regex)" : ""):"]
        var currentPath = ""
        for match in result.matches {
            if match.path != currentPath {
                currentPath = match.path
                lines.append(match.path)
            }
            lines.append("  \(match.line): \(match.text)")
        }
        if result.truncated {
            lines.append("(There are more matches. Narrow the search with path_glob or a more exact query.)")
        }
        return ToolOutput(
            forModel: lines.joined(separator: "\n"),
            summary: "Searched for \(described) · \(result.matches.count)\(result.truncated ? "+" : "") match\(result.matches.count == 1 && !result.truncated ? "" : "es")",
            detail: lines.dropFirst().prefix(60).joined(separator: "\n")
        )
    }
}
