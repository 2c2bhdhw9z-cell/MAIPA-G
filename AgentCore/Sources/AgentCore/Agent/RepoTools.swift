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

/// The same read result with strict decoding metadata retained for format-preserving edits.
enum DecodedFileRead: Sendable {
    case text(TextFileCodec.Document, bytes: Int)
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
    public nonisolated let repo: RepoRef
    public nonisolated let branch: String
    public nonisolated let commit: String
    private let github: GitHubClient
    private let store: SnapshotStore
    private var treeTask: Task<GitTree, Error>?
    private var snapshotTask: Task<RepoSnapshot, Error>?
    private var snapshot: RepoSnapshot?
    private static let maxFileCacheBytes = 64 * 1024 * 1024
    private var fileCache: [String: Data] = [:]
    private var fileCacheOrder: [String] = []
    private var fileCacheBytes = 0
    private var listeners: [UUID: @Sendable (SnapshotProgress) -> Void] = [:]

    private func insertFileCache(_ key: String, data: Data) {
        guard data.count <= Self.maxFileCacheBytes else { return }
        if let old = fileCache[key] {
            fileCacheBytes -= old.count
            fileCacheOrder.removeAll { $0 == key }
        }
        fileCache[key] = data
        fileCacheOrder.append(key)
        fileCacheBytes += data.count
        while fileCacheBytes > Self.maxFileCacheBytes, !fileCacheOrder.isEmpty {
            let evictedKey = fileCacheOrder.removeFirst()
            if let evicted = fileCache.removeValue(forKey: evictedKey) {
                fileCacheBytes -= evicted.count
            }
        }
    }

    public init(repo: RepoRef, branch: String, commit: String, github: GitHubClient, store: SnapshotStore) {
        self.repo = repo
        self.branch = branch
        self.commit = commit
        self.github = github
        self.store = store
    }

    public nonisolated func advancing(toCommit newCommit: String, branch newBranch: String? = nil) -> RepoWorkspace {
        RepoWorkspace(repo: repo, branch: newBranch ?? branch, commit: newCommit, github: github, store: store)
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
        switch try await readDecodedFile(rawPath) {
        case .text(let document, let bytes): return .text(document.text, bytes: bytes)
        case .binary(let bytes): return .binary(bytes: bytes)
        case .tooLarge(let bytes): return .tooLarge(bytes: bytes)
        case .folder: return .folder
        case .symlink(let target): return .symlink(target: target)
        case .missing(let suggestions): return .missing(suggestions: suggestions)
        }
    }

    /// A Git LFS pointer is replaced by the real file, checked against its recorded checksum.
    func resolvingLFS(_ data: Data, path: String) async throws -> DecodedFileRead? {
        guard let pointer = GitLFSPointer.parse(data) else { return nil }
        guard pointer.size <= SnapshotStore.maxStoredFileSize else { return .tooLarge(bytes: pointer.size) }
        let real: Data
        if let cached = fileCache["lfs:" + pointer.oid] {
            real = cached
        } else {
            real = try await github.lfsObject(repo, pointer: pointer)
            insertFileCache("lfs:" + pointer.oid, data: real)
        }
        guard let document = TextFileCodec.decode(real) else { return .binary(bytes: real.count) }
        return .text(document, bytes: real.count)
    }

    /// A file inside a submodule is read from the submodule's own GitHub repo at the exact
    /// commit this repo pins.
    func readFromSubmodule(_ path: String, tree: GitTree) async throws -> DecodedFileRead? {
        guard let link = tree.entries.first(where: { $0.type == "commit" && path.hasPrefix($0.path + "/") }) else { return nil }
        guard case .text(let document, _) = try await readDecodedFile(".gitmodules"),
              let module = GitSubmodules.parse(document.text, parent: repo).first(where: { $0.path == link.path })
        else { throw ToolInputError("\(link.path) is a submodule whose source isn't on GitHub, so MAIPA-G can't read inside it.") }
        let inner = String(path.dropFirst(link.path.count + 1))
        let data: Data
        do {
            data = try await github.fileContents(module.repo, path: inner, ref: link.sha)
        } catch let error as GitHubAPIError where error.isNotFound {
            throw ToolInputError("\(inner) wasn't found in the submodule \(module.repo.fullName) at \(link.sha.prefix(7)), or MAIPA-G's GitHub app can't see that repo.")
        }
        if let lfs = try await resolvingLFS(data, path: path) { return lfs }
        guard let document = TextFileCodec.decode(data) else { return .binary(bytes: data.count) }
        return .text(document, bytes: data.count)
    }

    func readDecodedFile(_ rawPath: String) async throws -> DecodedFileRead {
        let path = Self.normalize(rawPath)
        if let snapshot, let file = snapshot.file(path) {
            switch file.kind {
            case .text:
                guard let data = snapshot.contents(of: path) else { return .binary(bytes: file.size) }
                if let lfs = try await resolvingLFS(data, path: path) { return lfs }
                guard let document = TextFileCodec.decode(data) else { return .binary(bytes: file.size) }
                return .text(document, bytes: data.count)
            case .binary: return .binary(bytes: file.size)
            case .tooLarge: return .tooLarge(bytes: file.size)
            case .symlink: return .symlink(target: file.linkTarget ?? "")
            }
        }
        let tree = try await tree()
        guard let entry = tree.entries.first(where: { $0.path == path }) else {
            if path.isEmpty { return .folder }
            if let inside = try await readFromSubmodule(path, tree: tree) { return inside }
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
        if let lfs = try await resolvingLFS(data, path: path) { return lfs }
        guard let document = TextFileCodec.decode(data) else { return .binary(bytes: data.count) }
        return .text(document, bytes: data.count)
    }

    /// Reads raw bytes for binary image inspection (up to `maxBytes`), fetching the blob from GitHub
    /// when a local text-only snapshot skipped binary entries.
    public func readRawBytes(_ rawPath: String, maxBytes: Int = 5 * 1024 * 1024) async throws -> Data? {
        let path = Self.normalize(rawPath)
        guard !path.isEmpty else { return nil }
        if let cached = fileCache[path], cached.count <= maxBytes {
            return cached
        }
        if let snapshot, let data = snapshot.contents(of: path), data.count <= maxBytes {
            return data
        }
        let tree = try await tree()
        guard let entry = tree.entries.first(where: { $0.path == path && $0.isFile }) else {
            return nil
        }
        if let size = entry.size, size > maxBytes {
            return nil
        }
        let raw = try await github.blob(repo, sha: entry.sha)
        guard raw.count <= maxBytes else { return nil }
        insertFileCache(path, data: raw)
        if let pointer = GitLFSPointer.parse(raw) {
            guard pointer.size <= maxBytes else { return nil }
            if let lfsCached = fileCache["lfs:" + pointer.oid] { return lfsCached }
            let real = try await github.lfsObject(repo, pointer: pointer)
            insertFileCache("lfs:" + pointer.oid, data: real)
            return real
        }
        return raw
    }

    static func normalize(_ path: String) -> String {
        var path = path.trimmingCharacters(in: .whitespacesAndNewlines)
        while path.hasPrefix("./") { path.removeFirst(2) }
        while path.hasPrefix("/") { path.removeFirst() }
        while path.hasSuffix("/.") { path.removeLast(2) }
        while path.hasSuffix("/") { path.removeLast() }
        while path.contains("/./") {
            path = path.replacingOccurrences(of: "/./", with: "/")
        }
        if path == "." { return "" }
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
    public let changes: ChangeWorkspace?
    /// The person's computer and the repo's checkout there (relative to its $HOME), for
    /// `on_computer`: the real folder, with files that exist only there.
    public let computer: ComputerControl?
    public let computerPath: String?
    public let name = "list_files"
    static let maxLines = 2_000

    public init(workspace: RepoWorkspace, changes: ChangeWorkspace? = nil, computer: ComputerControl? = nil, computerPath: String? = nil) {
        self.workspace = workspace
        self.changes = changes
        self.computer = computer
        self.computerPath = computerPath
    }

    public var spec: ToolSpec {
        ToolSpec(
            name: name,
            description: """
            List the files and folders in the repository. Give a folder to look inside it (leave empty or "." \
            for the repository root), and a depth to see deeper. Give a pattern (like "*.swift" or "src/**/*.ts") \
            to find files by name anywhere. Set count_lines to true to count exact line totals across matching text files in one step. \
            It lists the repo at this chat's commit plus staged changes; set on_computer to true to list the real checkout on the \
            person's computer instead (with build output and other files that exist only there; path may then also be an absolute folder).
            """,
            parameters: [
                "type": "object",
                "properties": [
                    "path": ["type": "string", "description": "Folder to list. Leave empty or \".\" for the top of the repository."],
                    "depth": ["type": "integer", "minimum": 1, "maximum": 12, "description": "How many folder levels to show. Default 3."],
                    "pattern": ["type": "string", "description": "Optional file-name pattern, such as \"*.swift\" or \"App/**/*.swift\"."],
                    "count_lines": ["type": "boolean", "description": "When true, counts exact lines in every matching text file and reports per-file + total line counts."],
                    "on_computer": ["type": "boolean", "description": "List the checkout on the person's computer instead of the repo copy. Default false."],
                    "where": ["type": "string", "enum": ["repo", "computer"], "description": "Same as on_computer: \"computer\" lists the computer's checkout."],
                ],
            ]
        )
    }

    public func runningSummary(for arguments: JSONValue) -> String {
        if arguments.optionalBool("count_lines") == true {
            let pat = arguments.optionalString("pattern") ?? "repo files"
            return "Counting lines in \(pat)…"
        }
        if let pattern = arguments.optionalString("pattern") { return "Looking for \(Format.quote(pattern))…" }
        if let path = arguments.optionalString("path").map(RepoWorkspace.normalize), !path.isEmpty { return "Looking in \(path)…" }
        return "Looking through the repo…"
    }

    public func run(arguments: JSONValue, progress: @escaping @Sendable (String) -> Void) async throws -> ToolOutput {
        if arguments.optionalBool("on_computer") == true || arguments.optionalString("where")?.lowercased() == "computer" {
            return try await listOnComputer(arguments)
        }
        let folder = RepoWorkspace.normalize(arguments.optionalString("path") ?? "")
        let depth = min(max(arguments.optionalInt("depth") ?? 3, 1), 12)
        let shouldCountLines = arguments.optionalBool("count_lines") ?? false
        let tree = if let changes { try await changes.mergedTree() } else { try await workspace.tree() }
        let prefix = folder.isEmpty ? "" : folder + "/"
        let inside = tree.entries.filter { folder.isEmpty || $0.path.hasPrefix(prefix) }

        if !folder.isEmpty, inside.isEmpty {
            if tree.entries.contains(where: { $0.path == folder && $0.isFile }) {
                throw ToolInputError("\(folder) is a file, not a folder. Use read_file to read it.")
            }
            let suggestions = RepoWorkspace.suggestions(for: folder, in: tree)
            throw ToolInputError("There is no folder \(folder)." + (suggestions.isEmpty ? "" : " Did you mean: " + suggestions.joined(separator: ", ") + "?"))
        }

        if shouldCountLines {
            let pattern = arguments.optionalString("pattern")
            let glob = pattern.map { Glob($0) }
            let matchingFiles = inside.filter { $0.isFile && (glob?.matches($0.path) ?? true) }
            let copy = try await workspace.localCopy { update in
                switch update {
                case .downloading(let bytes): progress("Downloading repo snapshot · \(Format.bytes(Int(bytes)))")
                case .unpacking(let files): progress("Unpacking · \(files) files")
                case .updating(let changed): progress("Updating · \(changed) file\(changed == 1 ? "" : "s")")
                }
            }
            var stagedMap: [String: StagedChange] = [:]
            if let changes {
                for sc in await changes.stagedChanges() { stagedMap[sc.path] = sc }
            }
            var totalLines = 0
            var totalBytes = 0
            var textFileCount = 0
            var perFile: [(path: String, lines: Int, bytes: Int)] = []
            for entry in matchingFiles {
                try Task.checkCancellation()
                let data: Data?
                if let sc = stagedMap[entry.path] {
                    switch sc {
                    case .write(_, let d, _): data = d
                    case .delete: data = nil
                    }
                } else {
                    data = copy.contents(of: entry.path)
                }
                guard let data, let doc = TextFileCodec.decode(data) else { continue }
                // Count newlines directly instead of allocating a split array
                let count = doc.text.reduce(0) { $0 + ($1 == "\n" ? 1 : 0) } + (doc.text.last != "\n" && !doc.text.isEmpty ? 1 : 0)
                totalLines += count
                totalBytes += data.count
                textFileCount += 1
                perFile.append((entry.path, count, data.count))
            }
            perFile.sort { $0.lines != $1.lines ? $0.lines > $1.lines : $0.path < $1.path }
            let label = pattern ?? (folder.isEmpty ? "all text files" : folder)
            var outLines = ["Line count for \(label): \(totalLines) total lines across \(textFileCount) text file\(textFileCount == 1 ? "" : "s") (\(Format.bytes(totalBytes)))"]
            for item in perFile.prefix(Self.maxLines) {
                outLines.append("\(item.lines)\t\(item.path)  (\(Format.bytes(item.bytes)))")
            }
            if perFile.count > Self.maxLines {
                outLines.append("…and \(perFile.count - Self.maxLines) smaller files (already included in the \(totalLines)-line total above).")
            }
            return ToolOutput(
                forModel: outLines.joined(separator: "\n"),
                summary: "Counted \(totalLines) lines across \(textFileCount) file\(textFileCount == 1 ? "" : "s")",
                detail: outLines.prefix(60).joined(separator: "\n")
            )
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
    public let changes: ChangeWorkspace?
    public let name = "read_file"
    static let defaultLines = 1_500
    static let maxLines = 4_000
    static let maxCharacters = 250_000
    static let maxLineLength = 4_000
    /// Most characters one read returns, JSON escaping included, so the result always fits the
    /// AI's tool-result limit whole and its footer (line counts, where to read on) is never cut.
    static var characterBudget: Int { min(maxCharacters, Transcript.maxToolResultCharacters - 2_000) }
    /// Files over the 2 MB the repo copy keeps are fetched whole up to this size and read in ranges.
    static let maxRangedBytes = 25 * 1024 * 1024

    public init(workspace: RepoWorkspace, changes: ChangeWorkspace? = nil) {
        self.workspace = workspace
        self.changes = changes
    }

    public var spec: ToolSpec {
        ToolSpec(
            name: name,
            description: """
            Read one file from the repository, with line numbers on the left (1-based). Use it to look at code or \
            text before you explain or change it; read several files in parallel when you need them. \
            Long files come back in parts: pass offset (0-based line) and limit (number of lines), or start_line and \
            end_line (1-based, inclusive), and the footer always says which lines you got and where to read on. \
            One read returns up to 1,500 lines (4,000 with an explicit range) and about 28,000 characters. \
            Files over 2 MB are read in ranges the same way. PNG/JPEG/GIF/WebP pictures come back as images for AIs that can see. \
            It also reads full tool outputs saved under ~/.maipa-g/outputs/ when a result was cut in the middle. \
            Don't use it to find a file (use file_search or list_files) or to look through many files (use search_code).
            """,
            parameters: [
                "type": "object",
                "properties": [
                    "path": ["type": "string", "description": "Path from the top of the repository, like \"App/Sources/Main.swift\", or a saved output path like \"~/.maipa-g/outputs/call_1.txt\"."],
                    "offset": ["type": "integer", "minimum": 0, "description": "Line to start from, 0-based (offset 0 is line 1). Default 0."],
                    "limit": ["type": "integer", "minimum": 1, "description": "How many lines to read from offset. Default: up to 1,500."],
                    "start_line": ["type": "integer", "minimum": 1, "description": "First line to read, 1-based. Same as offset + 1; wins over offset when both are given."],
                    "end_line": ["type": "integer", "minimum": 1, "description": "Last line to read, 1-based and inclusive. Wins over limit when both are given."],
                ],
                "required": ["path"],
            ]
        )
    }

    public func runningSummary(for arguments: JSONValue) -> String {
        "Reading \(Format.lastComponent(arguments.optionalString("path") ?? "a file"))…"
    }

    public func run(arguments: JSONValue, progress: @escaping @Sendable (String) -> Void) async throws -> ToolOutput {
        let rawPath = try arguments.requiredString("path").trimmingCharacters(in: .whitespacesAndNewlines)
        if let saver = ToolOutputArchive.current, let saved = saver.savedText(at: rawPath) {
            return try Self.render(path: rawPath, text: saved, bytes: saved.utf8.count, arguments: arguments, note: "saved tool output")
        }
        if Self.looksLikeSavedOutput(rawPath) {
            throw ToolInputError("The saved output \(rawPath) isn't here any more (or was saved on another device). Run the tool again, on a smaller part if you can.")
        }
        let path = RepoWorkspace.normalize(rawPath)
        let readResult: FileRead
        if let changes {
            do {
                readResult = try await changes.read(path)
            } catch ChangeWorkspaceError.unsafePath {
                readResult = .missing(suggestions: [])
            }
        } else {
            readResult = try await workspace.readFile(path)
        }
        switch readResult {
        case .missing(let suggestions):
            throw ToolInputError("There is no file \(path)." + (suggestions.isEmpty ? " Use file_search, list_files or search_code to find it." : " Did you mean: " + suggestions.joined(separator: ", ") + "?"))
        case .folder:
            throw ToolInputError("\(path.isEmpty ? "That" : path) is a folder. Use list_files to see what is in it.")
        case .binary(let bytes):
            let rawData = try? await (changes != nil ? changes!.readRawBytes(path) : workspace.readRawBytes(path))
            if let data = rawData, let imageInfo = BinaryImageInspector.inspect(data, path: path) {
                let dimText = imageInfo.dimensions.map { "\($0.width)×\($0.height), " } ?? ""
                return ToolOutput(
                    forModel: "Repository image \(path) (\(imageInfo.formatName), \(dimText)\(Format.bytes(data.count))). Vision-capable AIs receive the visual image directly; text-only AIs receive its format and dimensions.",
                    summary: "Viewed image \(path)",
                    detail: "\(imageInfo.formatName) · \(dimText)\(Format.bytes(data.count))",
                    inlineImages: [ToolInlineImage(name: path, mimeType: imageInfo.mimeType, data: data)]
                )
            }
            return ToolOutput(forModel: "\(path) is a binary file (\(Format.bytes(bytes))), such as a picture or an archive. It can't be shown as text.", summary: "Looked at \(path) · not text")
        case .tooLarge(let bytes):
            // The repo copy doesn't keep files over 2 MB, so the file is fetched whole and read in
            // ranges like any other.
            if bytes <= Self.maxRangedBytes,
               let raw = try? await (changes != nil ? changes!.readRawBytes(path, maxBytes: Self.maxRangedBytes) : workspace.readRawBytes(path, maxBytes: Self.maxRangedBytes)) {
                guard let document = TextFileCodec.decode(raw) else {
                    return ToolOutput(forModel: "\(path) is a binary file (\(Format.bytes(raw.count))). It can't be shown as text.", summary: "Looked at \(path) · not text")
                }
                return try Self.render(path: path, text: document.text, bytes: raw.count, arguments: arguments, note: "large file: read it in ranges with offset and limit")
            }
            return ToolOutput(
                forModel: "\(path) is \(Format.bytes(bytes)), too large to fetch here. Read it in ranges on the computer instead, for example run_command with `sed -n '1,400p' \(path)` (then '401,800p' and so on), or `grep -n` for the part you need.",
                summary: "Looked at \(path) · too large"
            )
        case .symlink(let target):
            return ToolOutput(forModel: "\(path) is a link to \(target).", summary: "Looked at \(path) · a link")
        case .text(let text, let bytes):
            return try Self.render(path: path, text: text, bytes: bytes, arguments: arguments)
        }
    }

    static func looksLikeSavedOutput(_ path: String) -> Bool {
        ["~/.maipa-g/outputs/", ".maipa-g/outputs/", "$HOME/.maipa-g/outputs/"].contains { path.hasPrefix($0) }
    }

    /// The lines asked for, numbered, within the line and character limits, with a header and a
    /// footer that always say which lines these are and how to read on.
    static func render(path: String, text: String, bytes: Int, arguments: JSONValue, note: String? = nil) throws -> ToolOutput {
        var lines: [Substring] = text.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.last == "" { lines.removeLast() }
        let total = lines.count
        if total == 0 {
            return ToolOutput(forModel: "\(path) is empty.", summary: "Read \(path) · empty")
        }
        let explicitStart = arguments.optionalInt("start_line") ?? arguments.optionalInt("offset").map { max($0, 0) + 1 }
        let requestedStart = max(explicitStart ?? 1, 1)
        guard requestedStart <= total else {
            throw ToolInputError("\(path) has \(total) line\(total == 1 ? "" : "s"), so there is nothing at line \(requestedStart). Read from offset \(max(0, total - 200)) (start_line \(max(1, total - 199))) to see the end of the file.")
        }
        let start = requestedStart
        let explicitEnd = arguments.optionalInt("end_line") ?? arguments.optionalInt("limit").map { start + max($0, 1) - 1 }
        let requestedEnd = explicitEnd.map { max($0, start) } ?? total
        let lineWindow = explicitEnd != nil ? maxLines : defaultLines
        var end = min(requestedEnd, total, start + lineWindow - 1)
        var header = "\(path) (\(Format.bytes(bytes)), \(total) lines\(note.map { "; \($0)" } ?? ""))"
        // Room for the header and the footer, so neither is ever cut off.
        let budget = characterBudget - Transcript.escapedLength(header) - 400
        var body: [String] = []
        var characters = 0
        var stoppedForSize = false
        for number in start...end {
            var line = String(lines[number - 1])
            if line.hasSuffix("\r") { line.removeLast() }
            if line.count > maxLineLength { line = String(line.prefix(maxLineLength)) + "… [truncated: line too long, \(line.count) characters]" }
            let numbered = String(repeating: " ", count: max(0, 6 - String(number).count)) + "\(number)\t" + line
            let cost = Transcript.escapedLength(numbered) + 2
            if characters + cost > budget, !body.isEmpty {
                end = number - 1
                stoppedForSize = true
                break
            }
            characters += cost
            body.append(numbered)
        }
        let isWhole = start == 1 && end == total
        if !isWhole { header += ", showing lines \(start)-\(end)" }
        var output = header + "\n" + body.joined(separator: "\n")
        if !isWhole {
            var footer = "\n(Lines \(start)-\(end) of \(total).)"
            if end < total {
                let why = stoppedForSize ? " Stopped here to stay within the size of one read." : ""
                footer = "\n(Lines \(start)-\(end) of \(total).\(why) \(total - end) more lines. Read on with offset \(end) (start_line \(end + 1)).)"
            }
            output += footer
        }
        return ToolOutput(
            forModel: output,
            summary: isWhole ? "Read \(path)" : "Read \(path) · lines \(start)–\(end)",
            detail: body.prefix(40).joined(separator: "\n")
        )
    }
}

// MARK: - search_code

public struct SearchCodeTool: AgentTool {
    public let workspace: RepoWorkspace
    public let changes: ChangeWorkspace?
    public let name = "search_code"
    static let defaultResults = 100
    static let defaultPerFile = 20
    static let defaultContext = 2

    public init(workspace: RepoWorkspace, changes: ChangeWorkspace? = nil) {
        self.workspace = workspace
        self.changes = changes
    }

    public var spec: ToolSpec {
        ToolSpec(
            name: name,
            description: """
            Search the text of every file in the repository for a word, a phrase or a regular expression, like grep. \
            Use it to find where something is defined or used before reading the file. Each match comes back with its \
            file, its line number (the same numbers read_file uses), its indentation, and context_lines lines before and \
            after it (default 2). Narrow it with path_glob (only these files, like "*.swift" or "docs/**") and exclude_glob \
            (leave these out, like "node_modules" or "*.min.js"). Returns up to max_results matching lines (default 100) and \
            max_per_file per file (default 20); very long lines end with "[truncated: line too long]". Staged edits are \
            searched too. Pictures, archives and files over 2 MB aren't searched. Don't use it to find a file by its name \
            (use file_search) or to read a whole file (use read_file).
            """,
            parameters: [
                "type": "object",
                "properties": [
                    "query": ["type": "string", "description": "The text to find, or the regular expression when regex is true."],
                    "regex": ["type": "boolean", "description": "Treat query as a regular expression (ICU syntax; ^ and $ match at line ends). Default false."],
                    "case_sensitive": ["type": "boolean", "description": "Match upper and lower case exactly. Default false."],
                    "path_glob": ["type": "string", "description": "Only search files whose path matches this pattern, like \"*.swift\" or \"App/**/*.swift\"."],
                    "exclude_glob": ["type": "string", "description": "Leave out files, or whole folders, whose path matches this pattern, like \"node_modules\", \"*.min.js\" or \"{build,dist}\"."],
                    "context_lines": ["type": "integer", "minimum": 0, "maximum": 10, "description": "Lines to show before and after each match. Default 2; 0 for matching lines only."],
                    "max_results": ["type": "integer", "minimum": 1, "maximum": 500, "description": "Most matching lines to return in all. Default 100."],
                    "max_per_file": ["type": "integer", "minimum": 1, "maximum": 500, "description": "Most matching lines to return from one file. Default 20."],
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
            maxResults: min(max(arguments.optionalInt("max_results") ?? Self.defaultResults, 1), 500),
            maxPerFile: min(max(arguments.optionalInt("max_per_file") ?? Self.defaultPerFile, 1), 500),
            contextLines: min(max(arguments.optionalInt("context_lines") ?? Self.defaultContext, 0), 10),
            excludeGlob: arguments.optionalString("exclude_glob")
        )
        let activeWorkspace = changes?.base ?? workspace
        let copy = try await activeWorkspace.localCopy { update in
            switch update {
            case .downloading(let bytes): progress("Getting a copy of the repo to search · \(Format.bytes(Int(bytes)))")
            case .unpacking(let files): progress("Unpacking the copy · \(files) files")
            case .updating(let changed): progress("Updating the copy · \(changed) changed file\(changed == 1 ? "" : "s")")
            }
        }
        let staged = await changes?.stagedChanges() ?? []
        let result: SearchResult
        do {
            result = try await CodeSearch.run(query, in: copy, stagedChanges: staged)
        } catch let error as SearchError {
            throw ToolInputError(error.description)
        }
        let described = Format.quote(query.pattern, limit: 60)
        guard !result.matches.isEmpty else {
            var text = "No matches for \(query.pattern) in \(result.filesSearched) files"
            if let glob = query.pathGlob { text += " matching \(glob)" }
            if let exclude = query.excludeGlob { text += " (leaving out \(exclude))" }
            text += "."
            if result.filesSkipped > 0 { text += " (\(result.filesSkipped) files are pictures, archives or too large to search.)" }
            return ToolOutput(forModel: text, summary: "Searched for \(described) · no matches")
        }
        let lines = Self.render(result, query: query)
        return ToolOutput(
            forModel: lines.joined(separator: "\n"),
            summary: "Searched for \(described) · \(result.matches.count)\(result.truncated ? "+" : "") match\(result.matches.count == 1 && !result.truncated ? "" : "es")",
            detail: lines.dropFirst().prefix(60).joined(separator: "\n")
        )
    }

    /// Grouped by file like ripgrep: `12: text` for a matching line, `11- text` for context, and
    /// `--` between parts of a file that aren't next to each other.
    static func render(_ result: SearchResult, query: SearchQuery) -> [String] {
        var lines = ["\(result.matches.count)\(result.truncated ? "+" : "") matching lines in \(result.filesMatched) file\(result.filesMatched == 1 ? "" : "s") for \(query.pattern)\(query.isRegex ? " (regex)" : ""):"]
        var order: [String] = []
        var byPath: [String: [SearchMatch]] = [:]
        for match in result.matches {
            if byPath[match.path] == nil { order.append(match.path) }
            byPath[match.path, default: []].append(match)
        }
        for path in order {
            lines.append(path)
            var shown: [Int: (text: String, isMatch: Bool)] = [:]
            for match in byPath[path] ?? [] {
                for context in match.contextBefore + match.contextAfter where shown[context.line] == nil {
                    shown[context.line] = (context.text, false)
                }
                shown[match.line] = (match.text, true)
            }
            var previous: Int?
            for number in shown.keys.sorted() {
                if let previous, number != previous + 1, query.contextLines > 0 { lines.append("  --") }
                let entry = shown[number]!
                lines.append("  \(number)\(entry.isMatch ? ":" : "-") \(entry.text)")
                previous = number
            }
        }
        if result.truncated {
            lines.append("(There are more matches. Narrow the search with path_glob, exclude_glob or a more exact query, or raise max_results / max_per_file.)")
        }
        return lines
    }
}

// MARK: - file_search

/// Finds files by part of their path, like Kiro's file_search: a substring anywhere in the path,
/// `^` to anchor it at the start and `$` at the end, and close (fuzzy) matches when nothing
/// contains it exactly.
public enum FileSearch {
    public struct Match: Sendable, Hashable {
        public var path: String
        public var isClose: Bool
    }

    public static func rank(_ rawQuery: String, in paths: [String], exclude: Glob? = nil, limit: Int = 10) -> (matches: [Match], total: Int) {
        var query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let anchoredStart = query.hasPrefix("^")
        if anchoredStart { query.removeFirst() }
        let anchoredEnd = query.hasSuffix("$")
        if anchoredEnd { query.removeLast() }
        while anchoredStart, query.hasPrefix("/") || query.hasPrefix("./") { query.removeFirst(query.hasPrefix("./") ? 2 : 1) }
        let needle = query.lowercased()
        guard !needle.isEmpty else { return ([], 0) }
        let candidates = paths.filter { path in !(exclude.map { CodeSearch.isExcluded(path, by: $0) } ?? false) }

        var exact: [(path: String, score: Int)] = []
        for path in candidates {
            let lower = path.lowercased()
            if anchoredStart && !lower.hasPrefix(needle) { continue }
            if anchoredEnd && !lower.hasSuffix(needle) { continue }
            guard anchoredStart || anchoredEnd || lower.contains(needle) else { continue }
            let name = lower.split(separator: "/").last.map(String.init) ?? lower
            var score = 1_000
            if name == needle { score += 600 }
            else if name.hasPrefix(needle) { score += 400 }
            else if name.contains(needle) { score += 250 }
            score -= min(lower.count, 300)
            exact.append((path, score))
        }
        exact.sort { $0.score != $1.score ? $0.score > $1.score : $0.path < $1.path }
        var matches = exact.prefix(limit).map { Match(path: $0.path, isClose: false) }
        var total = exact.count
        if matches.count < limit, !anchoredStart, !anchoredEnd {
            let taken = Set(exact.map(\.path))
            var close: [(path: String, score: Int)] = []
            for path in candidates where !taken.contains(path) {
                if let score = fuzzyScore(needle, path.lowercased()) { close.append((path, score)) }
            }
            close.sort { $0.score != $1.score ? $0.score > $1.score : $0.path < $1.path }
            total += close.count
            matches += close.prefix(limit - matches.count).map { Match(path: $0.path, isClose: true) }
        }
        return (matches, total)
    }

    /// The characters of `needle` in order somewhere in `path`, scored higher when they are close
    /// together and in the file name. Nil when they aren't all there.
    static func fuzzyScore(_ needle: String, _ path: String) -> Int? {
        let characters = Array(path)
        let nameStart = (characters.lastIndex(of: "/") ?? -1) + 1
        var position = 0
        var score = 0
        var lastMatch = -1
        for wanted in needle where !wanted.isWhitespace {
            guard let found = characters[position...].firstIndex(of: wanted) else { return nil }
            if lastMatch >= 0 { score -= min(found - lastMatch - 1, 20) }
            if found >= nameStart { score += 3 }
            lastMatch = found
            position = found + 1
        }
        return score - min(characters.count, 300) / 10
    }
}

public struct FileSearchTool: AgentTool {
    public let workspace: RepoWorkspace
    public let changes: ChangeWorkspace?
    public let name = "file_search"
    static let maxResults = 10

    public init(workspace: RepoWorkspace, changes: ChangeWorkspace? = nil) {
        self.workspace = workspace
        self.changes = changes
    }

    public var spec: ToolSpec {
        ToolSpec(
            name: name,
            description: """
            Find files in the repository by part of their path, when you know some of the name but not where it is. \
            Matches the text anywhere in the path, ignoring case; start the query with ^ to match the start of the path \
            ("^App/Sources") and end it with $ to match the end ("View.swift$"). When nothing contains the text exactly, \
            close (fuzzy) matches are shown and marked. Leave files out with exclude (a pattern like "node_modules" or "*.test.ts"). \
            Returns at most 10 paths, best first, with the total count. Staged new files are included. \
            Don't use it to search inside files (use search_code) or to see a folder (use list_files).
            """,
            parameters: [
                "type": "object",
                "properties": [
                    "query": ["type": "string", "description": "Part of the file path, like \"ChatSession\" or \"^App/\" or \".swift$\"."],
                    "exclude": ["type": "string", "description": "Leave out files, or whole folders, whose path matches this pattern."],
                ],
                "required": ["query"],
            ]
        )
    }

    public func runningSummary(for arguments: JSONValue) -> String {
        "Looking for files named \(Format.quote(arguments.optionalString("query") ?? ""))…"
    }

    public func run(arguments: JSONValue, progress: @escaping @Sendable (String) -> Void) async throws -> ToolOutput {
        let query = try arguments.requiredString("query")
        let trimmed = query.trimmingCharacters(in: CharacterSet(charactersIn: "^$ \n\t"))
        guard !trimmed.isEmpty else { throw ToolInputError("Give part of a file path in `query`, like \"Session\" or \"^App/\".") }
        let exclude = arguments.optionalString("exclude")
        let tree = if let changes { try await changes.mergedTree() } else { try await workspace.tree() }
        let files = tree.entries.filter(\.isFile)
        let sizes = Dictionary(files.map { ($0.path, $0.size ?? 0) }, uniquingKeysWith: { first, _ in first })
        let ranked = FileSearch.rank(query, in: files.map(\.path), exclude: exclude.map { Glob($0) }, limit: Self.maxResults)
        let described = Format.quote(query, limit: 60)
        guard !ranked.matches.isEmpty else {
            return ToolOutput(
                forModel: "No file path matches \(query) among \(files.count) files\(exclude.map { " (leaving out \($0))" } ?? ""). Try a shorter part of the name, or list_files with a pattern.",
                summary: "Looked for \(described) · none found"
            )
        }
        var lines = ["Files matching \(query) (\(ranked.matches.count) of \(ranked.total)):"]
        for match in ranked.matches {
            lines.append("\(match.path)  \(Format.bytes(sizes[match.path] ?? 0))\(match.isClose ? "  (close match)" : "")")
        }
        if ranked.total > ranked.matches.count {
            lines.append("(Showing \(ranked.matches.count) of \(ranked.total). Make the query more exact, anchor it with ^ or $, or use list_files with a pattern to see them all.)")
        }
        return ToolOutput(
            forModel: lines.joined(separator: "\n"),
            summary: "Found \(ranked.total) file\(ranked.total == 1 ? "" : "s") for \(described)",
            detail: lines.dropFirst().joined(separator: "\n")
        )
    }
}

enum BinaryImageInspector {
    struct Info: Sendable, Hashable {
        var mimeType: String
        var formatName: String
        var dimensions: (width: Int, height: Int)?

        static func == (lhs: Info, rhs: Info) -> Bool {
            lhs.mimeType == rhs.mimeType
                && lhs.formatName == rhs.formatName
                && lhs.dimensions?.width == rhs.dimensions?.width
                && lhs.dimensions?.height == rhs.dimensions?.height
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(mimeType)
            hasher.combine(formatName)
            hasher.combine(dimensions?.width)
            hasher.combine(dimensions?.height)
        }
    }

    static func inspect(_ data: Data, path: String) -> Info? {
        let bytes = [UInt8](data.prefix(64))
        // PNG: 89 50 4E 47 0D 0A 1A 0A + IHDR width(16..19) height(20..23)
        if bytes.count >= 24,
           bytes[0] == 0x89, bytes[1] == 0x50, bytes[2] == 0x4E, bytes[3] == 0x47,
           bytes[4] == 0x0D, bytes[5] == 0x0A, bytes[6] == 0x1A, bytes[7] == 0x0A {
            let w = Int(UInt32(bytes[16]) << 24 | UInt32(bytes[17]) << 16 | UInt32(bytes[18]) << 8 | UInt32(bytes[19]))
            let h = Int(UInt32(bytes[20]) << 24 | UInt32(bytes[21]) << 16 | UInt32(bytes[22]) << 8 | UInt32(bytes[23]))
            return Info(mimeType: "image/png", formatName: "PNG", dimensions: (w > 0 && h > 0) ? (w, h) : nil)
        }
        // GIF: GIF87a / GIF89a + little-endian width(6..7) height(8..9)
        if bytes.count >= 10,
           bytes[0] == 0x47, bytes[1] == 0x49, bytes[2] == 0x46, bytes[3] == 0x38 {
            let w = Int(UInt16(bytes[6]) | (UInt16(bytes[7]) << 8))
            let h = Int(UInt16(bytes[8]) | (UInt16(bytes[9]) << 8))
            return Info(mimeType: "image/gif", formatName: "GIF", dimensions: (w > 0 && h > 0) ? (w, h) : nil)
        }
        // WebP: RIFF....WEBP
        if bytes.count >= 16,
           bytes[0] == 0x52, bytes[1] == 0x49, bytes[2] == 0x46, bytes[3] == 0x46,
           bytes[8] == 0x57, bytes[9] == 0x45, bytes[10] == 0x42, bytes[11] == 0x50 {
            var dims: (Int, Int)?
            if bytes.count >= 30, bytes[12] == 0x56, bytes[13] == 0x50, bytes[14] == 0x38, bytes[15] == 0x58 {
                let w = 1 + Int(UInt32(bytes[24]) | (UInt32(bytes[25]) << 8) | (UInt32(bytes[26]) << 16))
                let h = 1 + Int(UInt32(bytes[27]) | (UInt32(bytes[28]) << 8) | (UInt32(bytes[29]) << 16))
                if w > 0, h > 0 { dims = (w, h) }
            }
            return Info(mimeType: "image/webp", formatName: "WebP", dimensions: dims)
        }
        // JPEG: FF D8 FF ... scan SOF markers for height/width
        if bytes.count >= 4, bytes[0] == 0xFF, bytes[1] == 0xD8, bytes[2] == 0xFF {
            let dims = parseJPEGDimensions(data)
            return Info(mimeType: "image/jpeg", formatName: "JPEG", dimensions: dims)
        }
        return nil
    }

    private static func parseJPEGDimensions(_ data: Data) -> (width: Int, height: Int)? {
        let count = min(data.count, 256 * 1024)
        guard count >= 11 else { return nil }
        return data.withUnsafeBytes { raw -> (width: Int, height: Int)? in
            guard let ptr = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return nil }
            var i = 2
            while i + 8 < count {
                if ptr[i] != 0xFF { i += 1; continue }
                while i < count && ptr[i] == 0xFF { i += 1 }
                guard i < count else { break }
                let marker = ptr[i]
                i += 1
                if marker == 0xD8 || marker == 0xD9 || (marker >= 0xD0 && marker <= 0xD7) || marker == 0x01 {
                    continue
                }
                guard i + 1 < count else { break }
                let segLen = Int(ptr[i]) << 8 | Int(ptr[i + 1])
                guard segLen >= 2 else { break }
                // SOF0..SOF3, SOF5..SOF7, SOF9..SOF11, SOF13..SOF15
                let isSOF = (marker >= 0xC0 && marker <= 0xCF) && marker != 0xC4 && marker != 0xC8 && marker != 0xCC
                if isSOF, i + 6 < count {
                    let h = Int(ptr[i + 3]) << 8 | Int(ptr[i + 4])
                    let w = Int(ptr[i + 5]) << 8 | Int(ptr[i + 6])
                    if w > 0, h > 0 { return (w, h) }
                }
                i += segLen
            }
            return nil
        }
    }
}

// MARK: - list_files on the computer

extension ListFilesTool {
    static let computerEntryLimit = 20_000

    /// The real folder on the person's computer: a tree to `depth` levels, or every file matching
    /// `pattern` (tracked and untracked files git doesn't ignore, when it is a git checkout).
    func listOnComputer(_ arguments: JSONValue) async throws -> ToolOutput {
        guard let computer else {
            throw ToolInputError("list_files can't reach the computer in this chat. Use run_command with `ls -la` or `find . -maxdepth 2` instead.")
        }
        let raw = arguments.optionalString("path") ?? ""
        let folder: (expression: String, display: String)
        if raw.hasPrefix("/") {
            folder = (ComputerControl.shellQuote(raw), raw)
        } else if raw == "~" || raw.hasPrefix("~/") {
            let rest = RepoWorkspace.normalize(String(raw.dropFirst()))
            folder = (rest.isEmpty ? "\"$HOME\"" : "\"$HOME\"/" + ComputerControl.shellQuote(rest), rest.isEmpty ? "~" : "~/\(rest)")
        } else {
            let inside = RepoWorkspace.normalize(raw)
            let base = computerPath.map { RepoWorkspace.normalize($0) } ?? ""
            let relative = [base, inside].filter { !$0.isEmpty }.joined(separator: "/")
            folder = (relative.isEmpty ? "\"$HOME\"" : "\"$HOME\"/" + ComputerControl.shellQuote(relative), relative.isEmpty ? "~" : "~/\(relative)")
        }
        guard !folder.display.contains("\n") else { throw ToolInputError("path must be one folder, without line breaks.") }
        let depth = min(max(arguments.optionalInt("depth") ?? 3, 1), 12)
        let pattern = arguments.optionalString("pattern")
        let missing = "maipa-g-no-such-folder"
        let listing: String
        if pattern != nil {
            listing = """
            if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then git ls-files -co --exclude-standard 2>/dev/null; \
            else find . -name .git -prune -o -type f -print 2>/dev/null | sed 's|^\\./||'; fi | head -n 200000
            """
        } else {
            listing = """
            find . -mindepth 1 -maxdepth \(depth) -name .git -prune -o -type d -print 2>/dev/null | sed 's|^\\./||; s|$|/|' | head -n \(Self.computerEntryLimit); \
            find . -mindepth 1 -maxdepth \(depth) -name .git -prune -o ! -type d -print 2>/dev/null | sed 's|^\\./||' | head -n \(Self.computerEntryLimit)
            """
        }
        let script = "if [ -d \(folder.expression) ]; then cd \(folder.expression) || exit 0; else echo \(missing); exit 0; fi; \(listing)"
        let output = ComputerControl.plainOutput(try await computer.run(script, timeout: 120))
        var entries = output.split(whereSeparator: \.isNewline).map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("(exit code") }
        if entries.contains(missing) {
            throw ToolInputError("There is no folder \(folder.display) on \(computer.machine). List a folder above it, or use run_command with ls.")
        }
        if let pattern {
            let glob = Glob(pattern)
            let matches = entries.filter { glob.matches($0) }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            var lines = ["Files matching \(pattern) in \(folder.display) on \(computer.machine) (\(matches.count)):"]
            lines += matches.prefix(Self.maxLines)
            if matches.count > Self.maxLines { lines.append("…and \(matches.count - Self.maxLines) more. Use a narrower pattern or folder.") }
            if matches.isEmpty { lines.append("(none)") }
            return ToolOutput(forModel: lines.joined(separator: "\n"), summary: "Looked for \(Format.quote(pattern)) on the computer · \(matches.count) found", detail: lines.dropFirst().prefix(60).joined(separator: "\n"))
        }
        entries = Array(Set(entries))
        let folders = Set(entries.filter { $0.hasSuffix("/") }.map { String($0.dropLast()) })
        var children: [String: [(name: String, path: String, isFolder: Bool)]] = [:]
        for entry in entries {
            let isFolder = entry.hasSuffix("/")
            let path = isFolder ? String(entry.dropLast()) : entry
            let parts = path.split(separator: "/")
            guard let name = parts.last else { continue }
            let parent = parts.dropLast().joined(separator: "/")
            children[parent, default: []].append((String(name), path, isFolder || folders.contains(path)))
        }
        var lines = ["\(folder.display) on \(computer.machine) (\(entries.count) entries to depth \(depth); .git not shown):"]
        var truncated = false
        func walk(_ parent: String, level: Int) {
            let items = (children[parent] ?? []).sorted { a, b in
                if a.isFolder != b.isFolder { return a.isFolder }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
            for item in items {
                if lines.count >= Self.maxLines { truncated = true; return }
                lines.append(String(repeating: "  ", count: level) + item.name + (item.isFolder ? "/" : ""))
                if item.isFolder { walk(item.path, level: level + 1) }
            }
        }
        walk("", level: 0)
        if entries.isEmpty { lines.append("(empty)") }
        if truncated || entries.count >= Self.computerEntryLimit { lines.append("…list cut short. Look inside one folder at a time, or use a pattern.") }
        return ToolOutput(forModel: lines.joined(separator: "\n"), summary: "Looked in \(folder.display) on the computer", detail: lines.prefix(80).joined(separator: "\n"))
    }
}
