import Foundation

public struct ChangeAuthorization: Sendable, Hashable {
    public enum Operation: Sendable, Hashable { case deletion, buildSetup }

    private var deletionPaths: Set<String>
    private var buildSetupPaths: Set<String>

    public init(deletion: Bool, buildSetup: Bool) {
        deletionPaths = deletion ? ["*"] : []
        buildSetupPaths = buildSetup ? ["*"] : []
    }

    public init(request: String) {
        deletionPaths = []
        buildSetupPaths = []
        let lines = request.components(separatedBy: .newlines)
        for original in lines {
            let line = original.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            let negative = ["do not", "don't", "dont", "never", "without", "no deletion", "no delete", "nothing"].contains(where: line.contains)
            guard !negative else { continue }
            for (verb, operation) in [("delete", Operation.deletion), ("remove", .deletion), ("change", .buildSetup), ("edit", .buildSetup), ("update", .buildSetup), ("add", .buildSetup), ("create", .buildSetup)] {
                guard let range = line.range(of: "\(verb) ") else { continue }
                let tail = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
                let words = tail.split(whereSeparator: { $0.isWhitespace || ",;:()[]{}".contains($0) })
                for word in words.prefix(4) {
                    let candidate = RepoWorkspace.normalize(String(word).trimmingCharacters(in: CharacterSet(charactersIn: "`\"'")))
                    guard !candidate.isEmpty, !["the", "a", "an", "file", "files", "anything", "everything", "workflow"].contains(candidate) else { continue }
                    if operation == .deletion {
                        deletionPaths.insert(candidate)
                        break
                    }
                    if ChangeWorkspace.isBuildSetup(candidate) {
                        buildSetupPaths.insert(candidate)
                        break
                    }
                }
            }
            if line.contains("change build setup") || line.contains("edit build setup") || line.contains("update build setup") {
                buildSetupPaths.insert("*")
            }
        }
    }

    public func allows(_ operation: Operation, path rawPath: String) -> Bool {
        let path = RepoWorkspace.normalize(rawPath).lowercased()
        let scopes = operation == .deletion ? deletionPaths : buildSetupPaths
        return scopes.contains("*") || scopes.contains(path)
    }

    public var deletion: Bool { deletionPaths.contains("*") }
    public var buildSetup: Bool { buildSetupPaths.contains("*") }
}

public actor ChangeSession {
    private var saved: [SaveReceipt]
    public init(receipts: [SaveReceipt] = []) { saved = receipts }
    public func record(_ receipt: SaveReceipt) { saved.append(receipt) }
    /// Marks a save's request as finished elsewhere (closed or merged on the website), so it is
    /// no longer continued.
    public func markResolved(_ id: UUID, as resolution: String) {
        if let index = saved.firstIndex(where: { $0.id == id }) { saved[index].resolution = resolution }
    }
    public func receipts() -> [SaveReceipt] { saved }
    /// The newest save still waiting in an open pull/merge request; for `repo` only when given,
    /// so a chat with several repos never continues another repo's request.
    public func activeReceipt(for repo: RepoRef? = nil) -> SaveReceipt? {
        saved.last { $0.pullRequest != nil && $0.resolution == nil && (repo == nil || $0.repo == repo) }
    }
}

public struct SaveChangesTool: AgentTool {
    public let workspace: ChangeWorkspace
    public let service: GitHubChangeService
    public let session: ChangeSession
    public let selectedBranch: String
    public let defaultBranch: String
    public let rules: RepoWriteRules
    /// What the person told the AI in this reply about how to save (set_saving_style).
    public let choice: SavingStyleChoice?
    public let name = "save_changes"
    public init(workspace: ChangeWorkspace, service: GitHubChangeService, session: ChangeSession, selectedBranch: String, defaultBranch: String, rules: RepoWriteRules, choice: SavingStyleChoice? = nil) {
        self.workspace = workspace; self.service = service; self.session = session; self.selectedBranch = selectedBranch; self.defaultBranch = defaultBranch; self.rules = rules; self.choice = choice
    }

    /// The rules with what the person said in this reply on top: their word wins.
    func effectiveRules() async -> RepoWriteRules {
        var effective = rules
        if let told = await choice?.straightToBranch {
            effective.directSave = told
            effective.directSaveFromPerson = true
            effective.reason = told ? "You asked for saves straight to the branch." : "You asked for pull requests."
        }
        return effective
    }

    /// Only a repo's rules file alone asks first; when the person chose direct saves, it saves.
    func needsDirectSaveApproval() async -> Bool {
        let effective = await effectiveRules()
        guard effective.directSave, !effective.directSaveFromPerson, selectedBranch == defaultBranch else { return false }
        return await session.activeReceipt(for: workspace.base.repo) == nil
    }
    public var spec: ToolSpec { ToolSpec(name: name, description: "Save all staged file changes safely. Repository rules decide direct save versus a pull request.", parameters: ["type": "object", "properties": ["title": ["type": "string"], "summary": ["type": "string"]], "required": ["title"]]) }
    public func runningSummary(for arguments: JSONValue) -> String { "Saving changes…" }
    public func approvalRequest(for arguments: JSONValue) async -> ToolApprovalRequest? {
        guard await needsDirectSaveApproval() else { return nil }
        return ToolApprovalRequest(question: "Allow MAIPA-G to save these staged changes directly to \(defaultBranch)?", allowLabel: "Save directly")
    }
    public func approvalAfterOutsideContent(for arguments: JSONValue) async -> ToolApprovalRequest? {
        guard await session.activeReceipt(for: workspace.base.repo) == nil else { return nil }
        let title = String((arguments.optionalString("title") ?? "Changes").prefix(160))
        return ToolApprovalRequest(question: "Allow MAIPA-G to push staged changes to \(workspace.base.repo.hostName) (\(title))?", allowLabel: "Save changes")
    }
    public func run(arguments: JSONValue, progress: @escaping @Sendable (String) -> Void) async throws -> ToolOutput {
        if await needsDirectSaveApproval() {
            throw ToolInputError("Saving directly to the default branch needs the person's approval.")
        }
        return try await save(arguments: arguments)
    }
    public func runApproved(arguments: JSONValue, progress: @escaping @Sendable (String) -> Void) async throws -> ToolOutput {
        try await save(arguments: arguments)
    }
    private func save(arguments: JSONValue) async throws -> ToolOutput {
        let title = try arguments.requiredString("title")
        let receipt = try await service.save(workspace, selectedBranch: selectedBranch, defaultBranch: defaultBranch, rules: await effectiveRules(), title: title, body: arguments.optionalString("summary") ?? "Changes made by MAIPA-G.", activeReceipt: await session.activeReceipt(for: workspace.base.repo))
        await session.record(receipt)
        if let pull = receipt.pullRequest {
            return ToolOutput(forModel: "Saved commit \(receipt.savedCommit) and opened \(receipt.repo.isGitLab ? "merge request !" : "pull request #")\(pull.number) in \(receipt.repo.fullName): \(pull.htmlURL)", summary: receipt.repo.isGitLab ? "Opened merge request !\(pull.number)" : "Opened pull request #\(pull.number)", detail: pull.htmlURL)
        }
        return ToolOutput(forModel: "Saved commit \(receipt.savedCommit) directly to \(receipt.branch) in \(receipt.repo.fullName).", summary: "Saved to \(receipt.branch)")
    }
}

public struct CreateFileTool: AgentTool {
    public let workspace: ChangeWorkspace
    public let authorization: ChangeAuthorization
    public let rules: RepoWriteRules
    public let name = "create_file"
    public init(workspace: ChangeWorkspace, authorization: ChangeAuthorization = ChangeAuthorization(request: ""), rules: RepoWriteRules = RepoWriteRules()) { self.workspace = workspace; self.authorization = authorization; self.rules = rules }
    public var spec: ToolSpec {
        ToolSpec(
            name: name,
            description: """
            Create a new UTF-8 text file in the repository with exactly this content. Parent folders are made as needed.             The file is staged, not saved: it goes to GitHub only with save_changes. A file that already exists is an error             unless you pass overwrite: true, which replaces the whole file. To change part of an existing file use             edit_file (old_text/new_text); to add to the end use append_file. Don't use it for binary files such as pictures.
            """,
            parameters: [
                "type": "object",
                "properties": [
                    "path": ["type": "string", "description": "Repository path of the new file, like \"Sources/App/NewView.swift\"."],
                    "content": ["type": "string", "description": "The complete file content."],
                    "overwrite": ["type": "boolean", "description": "Replace the file if it already exists. Default false (an existing file is an error)."],
                ],
                "required": ["path", "content"],
            ]
        )
    }
    public func runningSummary(for arguments: JSONValue) -> String { "Creating \(arguments.optionalString("path") ?? "a file")…" }
    public func approvalRequest(for arguments: JSONValue) async -> ToolApprovalRequest? {
        guard let path = arguments.optionalString("path"), ChangeWorkspace.isBuildSetup(RepoWorkspace.normalize(path)),
              !authorization.allows(.buildSetup, path: path) else { return nil }
        return ToolApprovalRequest(question: "Allow MAIPA-G to add the build-setup file \(path)?")
    }
    public func run(arguments: JSONValue, progress: @escaping @Sendable (String) -> Void) async throws -> ToolOutput {
        let path = try arguments.requiredString("path")
        if ChangeWorkspace.isBuildSetup(RepoWorkspace.normalize(path)), !rules.permitsBuildSetup(at: path) { throw ToolInputError("Repository rules do not allow changing build setup at \(path).") }
        guard let content = arguments["content"]?.stringValue else { throw ToolInputError("Missing \"content\".") }
        let overwrite = arguments.optionalBool("overwrite") ?? false
        let existed = overwrite ? await workspace.exists(path) : false
        try await workspace.create(path: path, text: content, buildSetupApproved: true, overwrite: overwrite)
        if existed {
            return ToolOutput(forModel: "Replaced the whole of \(path) (staged, \(content.utf8.count) bytes).", summary: "Replaced \(path)", detail: content)
        }
        return ToolOutput(forModel: "Staged new file \(path).", summary: "Created \(path)", detail: content)
    }
}

public struct EditFileTool: AgentTool {
    public let workspace: ChangeWorkspace
    public let authorization: ChangeAuthorization
    public let rules: RepoWriteRules
    public let name = "edit_file"
    public init(workspace: ChangeWorkspace, authorization: ChangeAuthorization = ChangeAuthorization(request: ""), rules: RepoWriteRules = RepoWriteRules()) { self.workspace = workspace; self.authorization = authorization; self.rules = rules }
    public var spec: ToolSpec {
        ToolSpec(
            name: name,
            description: """
            Stage an edit to an existing UTF-8 text file (not saved to GitHub until save_changes). \
            Prefer surgical edits with old_text and new_text so large files are never truncated or rewritten from scratch; \
            only pass content when intentionally replacing an entire small file. old_text must match one place exactly \
            (or every place with replace_all); if it only matches once leading/trailing spaces are ignored, that one place \
            is replaced and the result says which lines.
            """,
            parameters: [
                "type": "object",
                "properties": [
                    "path": ["type": "string", "description": "Repository path of the file to edit."],
                    "old_text": ["type": "string", "description": "Exact existing lines to find in the file (include enough surrounding lines to be unique)."],
                    "new_text": ["type": "string", "description": "Replacement text for old_text (use \"\" to delete the matched lines)."],
                    "replace_all": ["type": "boolean", "description": "Replace every occurrence of old_text instead of requiring a single match. Default false."],
                    "content": ["type": "string", "description": "Complete new file content when replacing an entire small file instead of using old_text/new_text."],
                ],
                "required": ["path"],
            ]
        )
    }
    public func runningSummary(for arguments: JSONValue) -> String { "Editing \(arguments.optionalString("path") ?? "a file")…" }
    public func approvalRequest(for arguments: JSONValue) async -> ToolApprovalRequest? {
        guard let path = arguments.optionalString("path"), ChangeWorkspace.isBuildSetup(RepoWorkspace.normalize(path)),
              !authorization.allows(.buildSetup, path: path) else { return nil }
        return ToolApprovalRequest(question: "Allow MAIPA-G to change the build setup in \(path)?")
    }
    public func run(arguments: JSONValue, progress: @escaping @Sendable (String) -> Void) async throws -> ToolOutput {
        let path = try arguments.requiredString("path")
        if ChangeWorkspace.isBuildSetup(RepoWorkspace.normalize(path)), !rules.permitsBuildSetup(at: path) {
            throw ToolInputError("Repository rules do not allow changing build setup at \(path).")
        }
        if let oldText = arguments["old_text"]?.stringValue {
            guard let newText = arguments["new_text"]?.stringValue else {
                throw ToolInputError("Missing \"new_text\" when using \"old_text\" in edit_file.")
            }
            let replaceAll = arguments.optionalBool("replace_all") ?? false
            let result = try await workspace.replace(
                path: path,
                oldText: oldText,
                newText: newText,
                replaceAll: replaceAll,
                buildSetupApproved: true
            )
            let noun = result.count == 1 ? "1 block" : "\(result.count) blocks"
            var note = ""
            if let lines = result.whitespaceTolerantLines {
                let span = lines.count == 1 ? "line \(lines.lowerBound)" : "lines \(lines.lowerBound)-\(lines.upperBound)"
                note = " old_text didn't match exactly, so a whitespace-tolerant match was used: it replaced \(span), whose text matched once leading and trailing spaces and tabs were ignored. Check the indentation there with read_file."
            }
            return ToolOutput(
                forModel: "Staged surgical edit to \(path) (\(noun) replaced).\(note)",
                summary: "Edited \(path)",
                detail: result.diffPreview
            )
        }
        if let content = arguments["content"]?.stringValue {
            try await workspace.edit(path: path, text: content, buildSetupApproved: true)
            return ToolOutput(forModel: "Staged changes to \(path).", summary: "Edited \(path)", detail: content)
        }
        throw ToolInputError("Pass \"old_text\" and \"new_text\" for a surgical edit, or \"content\" to replace the entire file.")
    }
}

public struct AppendFileTool: AgentTool {
    public let workspace: ChangeWorkspace
    public let authorization: ChangeAuthorization
    public let rules: RepoWriteRules
    public let name = "append_file"
    public init(workspace: ChangeWorkspace, authorization: ChangeAuthorization = ChangeAuthorization(request: ""), rules: RepoWriteRules = RepoWriteRules()) { self.workspace = workspace; self.authorization = authorization; self.rules = rules }
    public var spec: ToolSpec {
        ToolSpec(
            name: name,
            description: "Stage UTF-8 text appended to the end of a repository file (or create it if create_if_missing is true) without rewriting existing lines. When the file doesn't end with a line break, one is added first so the new text starts on its own line.",
            parameters: [
                "type": "object",
                "properties": [
                    "path": ["type": "string", "description": "Repository path of the file."],
                    "content": ["type": "string", "description": "Text to append at the end of the file."],
                    "create_if_missing": ["type": "boolean", "description": "Create the file if it does not exist yet. Default false."],
                ],
                "required": ["path", "content"],
            ]
        )
    }
    public func runningSummary(for arguments: JSONValue) -> String { "Appending to \(arguments.optionalString("path") ?? "a file")…" }
    public func approvalRequest(for arguments: JSONValue) async -> ToolApprovalRequest? {
        guard let path = arguments.optionalString("path"), ChangeWorkspace.isBuildSetup(RepoWorkspace.normalize(path)),
              !authorization.allows(.buildSetup, path: path) else { return nil }
        return ToolApprovalRequest(question: "Allow MAIPA-G to change the build setup in \(path)?")
    }
    public func run(arguments: JSONValue, progress: @escaping @Sendable (String) -> Void) async throws -> ToolOutput {
        let path = try arguments.requiredString("path")
        if ChangeWorkspace.isBuildSetup(RepoWorkspace.normalize(path)), !rules.permitsBuildSetup(at: path) {
            throw ToolInputError("Repository rules do not allow changing build setup at \(path).")
        }
        guard let content = arguments["content"]?.stringValue else { throw ToolInputError("Missing \"content\".") }
        let createIfMissing = arguments.optionalBool("create_if_missing") ?? false
        let addedLineBreak = await workspace.needsLineBreakBeforeAppend(path)
        let created = try await workspace.append(path: path, text: content, createIfMissing: createIfMissing, buildSetupApproved: true)
        return ToolOutput(
            forModel: created ? "Created \(path) and staged content (\(content.utf8.count) bytes)." : "Staged \(content.utf8.count) bytes appended to \(path).\(addedLineBreak ? " The file didn't end with a line break, so one was added before the new text." : "")",
            summary: created ? "Created \(path)" : "Appended to \(path)",
            detail: String(content.prefix(10_000))
        )
    }
}

public struct DeleteFileTool: AgentTool {
    public let workspace: ChangeWorkspace
    public let authorization: ChangeAuthorization
    public let rules: RepoWriteRules
    public let name = "delete_file"
    public init(workspace: ChangeWorkspace, authorization: ChangeAuthorization = ChangeAuthorization(request: ""), rules: RepoWriteRules = RepoWriteRules()) { self.workspace = workspace; self.authorization = authorization; self.rules = rules }
    public var spec: ToolSpec {
        ToolSpec(
            name: name,
            description: """
            Delete one file from the repository: text or binary (pictures, archives, large files) or a link. The deletion is \
            staged and goes to GitHub only with save_changes; until then it can be undone. MAIPA-G asks the person first when \
            its settings say so. Folders aren't deleted in one go: delete the files inside them. Don't use it to empty a file \
            (use edit_file) or to rename one (create_file the new path, then delete the old one).
            """,
            parameters: ["type": "object", "properties": ["path": ["type": "string", "description": "Repository path of the file to delete."]], "required": ["path"]]
        )
    }
    public func runningSummary(for arguments: JSONValue) -> String { "Deleting \(arguments.optionalString("path") ?? "a file")…" }
    public func approvalRequest(for arguments: JSONValue) async -> ToolApprovalRequest? {
        guard let path = arguments.optionalString("path") else { return nil }
        return ToolApprovalRequest(question: "Allow MAIPA-G to delete \(path)?")
    }
    public func run(arguments: JSONValue, progress: @escaping @Sendable (String) -> Void) async throws -> ToolOutput {
        let path = try arguments.requiredString("path")
        throw ChangeWorkspaceError.deletionApprovalRequired(path)
    }
    public func runApproved(arguments: JSONValue, progress: @escaping @Sendable (String) -> Void) async throws -> ToolOutput {
        let path = try arguments.requiredString("path")
        guard rules.permitsDeletion(at: path) else { throw ToolInputError("Repository rules do not allow deleting \(path).") }
        try await workspace.delete(path: path, approved: true)
        return ToolOutput(forModel: "Staged deletion of \(path).", summary: "Deleted \(path)")
    }
}


// MARK: How the person wants changes saved

/// What the person said, in this reply, about saving straight to the branch or as a pull request.
public actor SavingStyleChoice {
    public private(set) var straightToBranch: Bool?
    public init(straightToBranch: Bool? = nil) { self.straightToBranch = straightToBranch }
    public func set(_ value: Bool) { straightToBranch = value }
}

/// Kiro does what it's told about branches: "only push to main" means it pushes to main, and
/// "use pull requests" means pull requests. This is how the AI records that. It applies from the
/// next save in this reply, and the app remembers it for later chats until the person says
/// otherwise (the app reads this tool's call when the reply ends).
public struct SetSavingStyleTool: AgentTool {
    public let name = "set_saving_style"
    let choice: SavingStyleChoice
    let repoName: String?

    public init(choice: SavingStyleChoice, repoName: String?) {
        self.choice = choice
        self.repoName = repoName
    }

    public var spec: ToolSpec {
        ToolSpec(name: name, description: "Call this whenever the person says how changes should be saved, in any wording: straight to the branch (e.g. \"only push to main\", \"no branches or PRs\", \"commit to master\") or as pull requests (e.g. \"use PRs\", \"make a branch\"). It takes effect for the next save_changes and is remembered for later chats. Never tell the person to change a setting for this, and never say you can't: call this tool.", parameters: [
            "type": "object",
            "properties": [
                "style": ["type": "string", "enum": ["straight_to_branch", "pull_request"]],
                "scope": ["type": "string", "enum": ["all_repos", "this_repo"], "description": "all_repos unless they named only this repo."],
            ],
            "required": ["style"],
            "additionalProperties": false,
        ])
    }

    public func runningSummary(for arguments: JSONValue) -> String { "Remembering how to save…" }

    public static func parse(_ arguments: JSONValue) -> (straightToBranch: Bool, allRepos: Bool)? {
        guard let style = arguments["style"]?.stringValue, ["straight_to_branch", "pull_request"].contains(style) else { return nil }
        return (style == "straight_to_branch", arguments["scope"]?.stringValue != "this_repo")
    }

    public func run(arguments: JSONValue, progress: @escaping @Sendable (String) -> Void) async throws -> ToolOutput {
        guard let parsed = Self.parse(arguments) else { throw ToolInputError("style must be straight_to_branch or pull_request.") }
        await choice.set(parsed.straightToBranch)
        let where_ = parsed.allRepos ? "every repo" : (repoName ?? "this repo")
        let how = parsed.straightToBranch ? "straight to the branch (no side branch or pull request)" : "on a side branch with a pull request"
        return ToolOutput(forModel: "From now on, changes in \(where_) save \(how). The app remembers this for later chats until the person says otherwise.", summary: "Saving \(parsed.straightToBranch ? "straight to the branch" : "as pull requests") · \(where_)")
    }
}
