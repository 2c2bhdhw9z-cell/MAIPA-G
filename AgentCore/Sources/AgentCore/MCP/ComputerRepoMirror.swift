import Foundation

/// One copy of the repo, the way Kiro has one folder. Before this, the AI's file tools changed a
/// staged copy on the phone side while its commands ran against a separate checkout on the
/// computer; the two only met when the AI remembered `sync_staged_to_computer`, which reset the
/// computer's copy (stashing its work). So tests ran on old files, edits made by commands were
/// undone, and the AI re-read and re-edited the same files over and over.
///
/// Now what a file tool writes goes onto the computer straight away, and what a command changes on
/// the computer comes back into the staged changes, so reads, edits, tests and saves all see the
/// same files. The repo's own safety rules still apply: a build-setup file or a deletion made by a
/// command is only staged when the file tools would have allowed it without asking.
public actor ComputerRepoMirror {
    /// Whether a change made on the computer may be staged without asking: (path, isDeletion).
    public typealias StageGate = @Sendable (_ path: String, _ deletion: Bool) -> Bool

    let control: ComputerControl
    let workspace: ChangeWorkspace
    let homePath: String
    let startCommit: String
    let cloneURL: String?
    let token: CheckoutToken?
    let gate: StageGate
    private var started = false
    private var unwritten: Set<String> = []
    private var mayHaveChanged = false

    /// Bigger files made by commands stay on the computer (build output, archives).
    static let maxFileBytes = 25 * 1024 * 1024
    /// New untracked files brought in per command at most; more is almost always build output.
    static let maxNewFiles = 400
    static let ignoredNewFiles = #"(^|/)(node_modules|\.venv|venv|__pycache__|\.build|Pods|DerivedData|\.gradle|\.next|\.expo|\.cache|\.turbo|\.pytest_cache)/|\.pyc$|(^|/)\.DS_Store$"#

    public init(control: ComputerControl, workspace: ChangeWorkspace, homePath: String, commit: String, cloneURL: String? = nil, token: CheckoutToken? = nil, gate: @escaping StageGate) {
        self.control = control
        self.workspace = workspace
        self.homePath = homePath
        self.startCommit = commit
        self.cloneURL = cloneURL
        self.token = token
        self.gate = gate
    }

    /// The file tools' own rules: a build-setup file needs the repo's permission and the
    /// person's words, and a deletion needs the person's words.
    public static func gate(authorization: ChangeAuthorization, rules: RepoWriteRules) -> StageGate {
        { path, deletion in
            if deletion, !authorization.allows(.deletion, path: path) { return false }
            if ChangeWorkspace.isBuildSetup(path), !(rules.permitsBuildSetup(at: path) && authorization.allows(.buildSetup, path: path)) { return false }
            return true
        }
    }

    public var isStarted: Bool { started }

    /// Puts the computer's copy at the chat's commit with the staged files on top, once. Work that
    /// was only on the computer goes to git stash first, never lost. Returns a note when it failed.
    @discardableResult
    public func start() async -> String? {
        if started { return nil }
        guard ComputerControl.isSafeRelativePath(homePath), startCommit.count >= 7, startCommit.allSatisfy(\.isHexDigit) else {
            return "MAIPA-G couldn't keep the repo's copy on the computer in step with your staged files, so commands may see older files."
        }
        do {
            _ = try await control.syncStagedChanges(homePath: homePath, cloneURL: cloneURL, commit: startCommit, changes: await workspace.stagedChanges(), token: token)
            started = true
            unwritten.removeAll()
            return nil
        } catch {
            return "MAIPA-G couldn't put the repo's copy on the computer in step with your staged files (\(ErrorExplainer.explain(error).message)), so this command may see older files."
        }
    }

    /// A file tool changed `path`: the same file goes onto the computer now.
    public func wrote(_ rawPath: String) async {
        let path = RepoWorkspace.normalize(rawPath)
        // Before the copy is started, starting it places every staged file anyway.
        guard started else { return }
        if await place(path) { unwritten.remove(path) } else { unwritten.insert(path) }
    }

    /// Before a command: the copy is started, and any file that couldn't go across is tried again.
    public func prepareForCommand() async -> String? {
        if !started { return await start() }
        for path in unwritten.sorted() {
            if await place(path) { unwritten.remove(path) }
        }
        guard !unwritten.isEmpty else { return nil }
        return "MAIPA-G couldn't put \(unwritten.sorted().prefix(10).joined(separator: ", ")) on the computer, so this command sees the older version of \(unwritten.count == 1 ? "that file" : "those files")."
    }

    /// A command left something running (in the background, or a long task): file tools look at
    /// the computer again before they read or write.
    public func markMayChange() { mayHaveChanged = true }

    /// Brings in what changed on the computer when a background command may still be writing.
    public func refreshIfNeeded() async {
        guard started, mayHaveChanged else { return }
        _ = await refresh()
        mayHaveChanged = true
    }

    // MARK: Computer → staged changes

    enum Seen: Equatable {
        case file(sha: String, bytes: Int)
        case gone
    }

    /// Brings what changed in the computer's copy into the staged changes. Returns a short note for
    /// the AI saying what came in and what was left out, or nil when nothing changed.
    public func refresh() async -> String? {
        guard started else { return nil }
        mayHaveChanged = false
        let staged = Dictionary(await workspace.stagedChanges().map { ($0.path, $0) }, uniquingKeysWith: { _, last in last })
        let script = Self.listScript(homePath: homePath, commit: startCommit, stagedPaths: staged.keys.sorted())
        guard let output = try? await control.run(script), output.contains("maipa-g-mirror-ok") else { return nil }
        let (seen, more) = Self.parse(output)
        guard !seen.isEmpty else { return more > 0 ? "\(more) new files on the computer weren't brought into your staged changes (too many; likely build output)." : nil }
        var baseSHA: [String: String] = [:]
        if let tree = try? await workspace.base.tree() {
            for entry in tree.entries where entry.isFile { baseSHA[entry.path] = entry.sha }
        }
        var broughtIn: [String] = [], removed: [String] = [], reverted: [String] = []
        var held: [String] = [], tooBig: [String] = [], secret: [String] = [], unread: [String] = []
        for (path, state) in seen.sorted(by: { $0.key < $1.key }) {
            let expected: String?
            switch staged[path] {
            case .write(_, let data, _)?: expected = Hashing.gitBlobID(data)
            case .delete?: expected = nil
            case nil: expected = baseSHA[path]
            }
            switch state {
            case .gone:
                guard expected != nil else { continue }
                if case .write(_, _, false)? = staged[path] {
                    // Made in this chat and deleted again before it was saved: nothing to keep.
                    await workspace.unstage(path)
                    removed.append(path)
                } else if gate(path, true) {
                    try? await workspace.stageDeletionFromComputer(path: path)
                    removed.append(path)
                } else {
                    held.append("\(path) (deleted there; delete_file asks first)")
                }
            case .file(let sha, let bytes):
                if sha == expected { continue }
                if let base = baseSHA[path], sha == base {
                    await workspace.unstage(path)
                    reverted.append(path)
                    continue
                }
                if bytes > Self.maxFileBytes { tooBig.append(path); continue }
                if ChangeWorkspace.isSecretShapedPath(path) { secret.append(path); continue }
                let alreadyStagedWrite: Bool = { if case .write? = staged[path] { return true } else { return false } }()
                if !alreadyStagedWrite, !gate(path, false) {
                    held.append("\(path) (build setup; edit_file asks first)")
                    continue
                }
                guard let data = await read(path) else { unread.append(path); continue }
                try? await workspace.stageFromComputer(path: path, data: data)
                broughtIn.append(path)
            }
        }
        return Self.note(broughtIn: broughtIn, removed: removed, reverted: reverted, held: held, tooBig: tooBig, secret: secret, unread: unread, more: more)
    }

    static func note(broughtIn: [String], removed: [String], reverted: [String], held: [String], tooBig: [String], secret: [String], unread: [String], more: Int) -> String? {
        func list(_ paths: [String]) -> String {
            paths.prefix(20).joined(separator: ", ") + (paths.count > 20 ? " and \(paths.count - 20) more" : "")
        }
        var parts: [String] = []
        if !broughtIn.isEmpty { parts.append("now staged as changed on the computer: \(list(broughtIn))") }
        if !removed.isEmpty { parts.append("staged as deleted: \(list(removed))") }
        if !reverted.isEmpty { parts.append("back to the repo's version: \(list(reverted))") }
        if !held.isEmpty { parts.append("left out until the person allows it: \(list(held))") }
        if !tooBig.isEmpty { parts.append("left on the computer only (over 25 MB): \(list(tooBig))") }
        if !secret.isEmpty { parts.append("left on the computer only (they look like secrets): \(list(secret))") }
        if !unread.isEmpty { parts.append("couldn't be read back: \(list(unread))") }
        if more > 0 { parts.append("\(more) more new files left on the computer only (likely build output)") }
        guard !parts.isEmpty else { return nil }
        return "[MAIPA-G: repo files this changed on the computer — " + parts.joined(separator: "; ") + ". read_file and save_changes see them.]"
    }

    /// Lists every file that differs from the chat's commit, new files the repo doesn't ignore,
    /// and every staged path, each with its git blob id and size (or gone). Then it remembers this
    /// tree as accounted for, so the next start doesn't stash it again.
    static func listScript(homePath: String, commit: String, stagedPaths: [String]) -> String {
        let quoted = stagedPaths.filter(ComputerControl.isSafeRelativeRepoPath).map(ComputerControl.shellQuote).joined(separator: " ")
        return """
        set -u
        cd "$HOME/\(homePath)" 2>/dev/null || { echo maipa-g-mirror-missing; exit 0; }
        report() { if [ -f "$1" ] && [ ! -L "$1" ]; then printf 'maipa-g-file\\t%s\\t%s\\t%s\\n' "$(git hash-object --no-filters -- "$1")" "$(wc -c < "$1" | tr -d ' ')" "$1"; elif [ ! -e "$1" ] && [ ! -L "$1" ]; then printf 'maipa-g-gone\\t%s\\n' "$1"; fi; }
        git -c core.quotepath=off diff --no-renames --name-only '\(commit)' -- 2>/dev/null | while IFS= read -r p; do [ -n "$p" ] && report "$p"; done
        new=$(git -c core.quotepath=off ls-files --others --exclude-standard 2>/dev/null | grep -v -E '\(ignoredNewFiles)' || true)
        n=$(printf '%s\\n' "$new" | grep -c . || true)
        printf '%s\\n' "$new" | head -n \(maxNewFiles) | while IFS= read -r p; do [ -n "$p" ] && report "$p"; done
        if [ "${n:-0}" -gt \(maxNewFiles) ]; then printf 'maipa-g-more\\t%s\\n' "$((n - \(maxNewFiles)))"; fi
        for p in \(quoted.isEmpty ? "''" : quoted); do [ -n "$p" ] && report "$p"; done
        idx=$(mktemp "${TMPDIR:-/tmp}/maipa-g-index.XXXXXX"); cp "$(git rev-parse --git-path index)" "$idx" 2>/dev/null || true
        (GIT_INDEX_FILE="$idx" git add -A >/dev/null 2>&1 && GIT_INDEX_FILE="$idx" git write-tree > "$(git rev-parse --git-path maipa-g-synced-tree)") 2>/dev/null || true
        rm -f "$idx"
        echo maipa-g-mirror-ok
        """
    }

    static func parse(_ output: String) -> (seen: [String: Seen], more: Int) {
        var seen: [String: Seen] = [:]
        var more = 0
        for line in output.components(separatedBy: "\n") {
            let fields = line.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
            switch fields.first {
            case "maipa-g-file" where fields.count == 4:
                let path = fields[3]
                guard Self.isListedPath(path), fields[1].count == 40, let bytes = Int(fields[2]) else { continue }
                seen[path] = .file(sha: fields[1], bytes: bytes)
            case "maipa-g-gone" where fields.count == 2:
                guard Self.isListedPath(fields[1]) else { continue }
                seen[fields[1]] = .gone
            case "maipa-g-more" where fields.count == 2:
                more = Int(fields[1]) ?? 0
            default:
                continue
            }
        }
        return (seen, more)
    }

    /// Git quotes a path it can't print plainly; those, and anything outside the repo, are skipped.
    static func isListedPath(_ path: String) -> Bool {
        !path.hasPrefix("\"") && ComputerControl.isSafeRelativeRepoPath(path) && (try? ChangeWorkspace.safe(path)) != nil
    }

    // MARK: Moving one file

    private var scratchName: String { ".maipa-g/mirror/\(UUID().uuidString.prefix(12).lowercased())" }

    /// Reads one repo file from the computer, through a scratch copy with a plain name.
    private func read(_ path: String) async -> Data? {
        guard ComputerControl.isSafeRelativeRepoPath(path) else { return nil }
        let scratch = scratchName
        let copied = try? await control.run("set -eu; umask 077; mkdir -p \"$HOME/.maipa-g/mirror\"; cp -- \"$HOME/\(homePath)\"/\(ComputerControl.shellQuote(path)) \"$HOME/\(scratch)\" && echo maipa-g-copied")
        guard copied?.contains("maipa-g-copied") == true else { return nil }
        let data = try? await control.readFile(homePath: scratch, maxBytes: Self.maxFileBytes)
        _ = try? await control.run("rm -f \"$HOME/\(scratch)\"")
        return data
    }

    /// Puts the staged version of one file on the computer (or deletes it, or puts the repo's
    /// version back when it is no longer staged). True when it is there.
    private func place(_ path: String) async -> Bool {
        guard ComputerControl.isSafeRelativeRepoPath(path), ComputerControl.isSafeRelativePath(homePath) else { return false }
        let quoted = ComputerControl.shellQuote(path)
        let repo = "\"$HOME/\(homePath)\""
        let content: Data?
        switch await workspace.stagedChange(for: path) {
        case .write(_, let data, _)?: content = data
        case .delete?: content = nil
        case nil: content = try? await workspace.readRawBytes(path, maxBytes: Self.maxFileBytes)
        }
        do {
            guard let content else {
                return try await control.run("cd \(repo) && rm -f -- \(quoted) && echo maipa-g-placed").contains("maipa-g-placed")
            }
            let scratch = scratchName
            try await control.writeFile(content, toHomePath: scratch)
            let script = """
            set -eu
            s="$HOME/\(scratch)"; trap 'rm -f "$s"' EXIT
            cd \(repo)
            p=\(quoted)
            mkdir -p "$(dirname -- "$p")"
            if [ -f "$p" ] && [ ! -L "$p" ]; then cat "$s" > "$p"; else rm -rf -- "$p"; cp "$s" "$p"; chmod 644 "$p"; fi
            echo maipa-g-placed
            """
            return try await control.run(script).contains("maipa-g-placed")
        } catch {
            return false
        }
    }
}

/// Wraps the repo and command tools so they share one copy with the computer (ComputerRepoMirror).
public struct ComputerMirroredTool: AgentTool {
    enum Role { case read, write, save, command }

    let inner: any AgentTool
    let mirror: ComputerRepoMirror
    let role: Role

    static func role(for name: String) -> Role? {
        switch name {
        case "read_file", "list_files", "search_code", "file_search", "load_spec": return .read
        case "create_file", "edit_file", "append_file", "delete_file": return .write
        case "save_changes": return .save
        case "run_command", "computer_task", "code", "app_preview": return .command
        default: return nil
        }
    }

    /// Wraps the tools that read, write, save or run commands; the rest are returned as they are.
    /// `sync_staged_to_computer` is dropped: the copies are always in step now, and its reset
    /// would put back an older commit after a save.
    public static func wrap(_ tools: [any AgentTool], mirror: ComputerRepoMirror) -> [any AgentTool] {
        tools.compactMap { tool in
            if tool.name == "sync_staged_to_computer" { return nil }
            guard let role = role(for: tool.name) else { return tool }
            return ComputerMirroredTool(inner: tool, mirror: mirror, role: role)
        }
    }

    public var name: String { inner.name }
    public var spec: ToolSpec { inner.spec }
    public var bringsOutsideContent: Bool { inner.bringsOutsideContent }
    public func runningSummary(for arguments: JSONValue) -> String { inner.runningSummary(for: arguments) }
    public func initialSubagents(for arguments: JSONValue, callID: String) -> [SubagentRunItem]? { inner.initialSubagents(for: arguments, callID: callID) }
    public func approvalRequest(for arguments: JSONValue) async -> ToolApprovalRequest? { await inner.approvalRequest(for: arguments) }
    public func approvalAfterOutsideContent(for arguments: JSONValue) async -> ToolApprovalRequest? { await inner.approvalAfterOutsideContent(for: arguments) }
    public func alwaysAsks(for arguments: JSONValue) async -> Bool { await inner.alwaysAsks(for: arguments) }

    public func run(arguments: JSONValue, progress: @escaping @Sendable (String) -> Void) async throws -> ToolOutput {
        try await around(arguments) { try await inner.run(arguments: arguments, progress: progress) }
    }
    public func runLive(arguments: JSONValue, update: @escaping @Sendable (ToolLiveUpdate) -> Void) async throws -> ToolOutput {
        try await around(arguments) { try await inner.runLive(arguments: arguments, update: update) }
    }
    public func runLive(arguments: JSONValue, callID: String, existingSubagents: [SubagentRunItem]?, update: @escaping @Sendable (ToolLiveUpdate) -> Void) async throws -> ToolOutput {
        try await around(arguments) { try await inner.runLive(arguments: arguments, callID: callID, existingSubagents: existingSubagents, update: update) }
    }
    public func runApproved(arguments: JSONValue, progress: @escaping @Sendable (String) -> Void) async throws -> ToolOutput {
        try await around(arguments) { try await inner.runApproved(arguments: arguments, progress: progress) }
    }
    public func runApprovedLive(arguments: JSONValue, update: @escaping @Sendable (ToolLiveUpdate) -> Void) async throws -> ToolOutput {
        try await around(arguments) { try await inner.runApprovedLive(arguments: arguments, update: update) }
    }
    public func runApprovedLive(arguments: JSONValue, callID: String, existingSubagents: [SubagentRunItem]?, update: @escaping @Sendable (ToolLiveUpdate) -> Void) async throws -> ToolOutput {
        try await around(arguments) { try await inner.runApprovedLive(arguments: arguments, callID: callID, existingSubagents: existingSubagents, update: update) }
    }

    func around(_ arguments: JSONValue, _ body: () async throws -> ToolOutput) async throws -> ToolOutput {
        switch role {
        case .read:
            await mirror.refreshIfNeeded()
            return try await body()
        case .save:
            if await mirror.isStarted { _ = await mirror.refresh() }
            return try await body()
        case .write:
            await mirror.refreshIfNeeded()
            let output = try await body()
            if !output.isError, let path = arguments["path"]?.stringValue { await mirror.wrote(path) }
            return output
        case .command:
            let before = await mirror.prepareForCommand()
            var output: ToolOutput
            do {
                output = try await body()
            } catch {
                _ = await mirror.refresh()
                throw error
            }
            let after = await mirror.refresh()
            if arguments["run_in_background"]?.boolValue == true || name == "computer_task" || name == "app_preview" {
                await mirror.markMayChange()
            }
            for note in [before, after].compactMap({ $0 }) { output.forModel += "\n\n" + note }
            return output
        }
    }
}
