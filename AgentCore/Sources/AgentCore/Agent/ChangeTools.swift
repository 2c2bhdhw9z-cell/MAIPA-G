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
    public func receipts() -> [SaveReceipt] { saved }
    public func activeReceipt() -> SaveReceipt? {
        saved.last { $0.pullRequest != nil && $0.resolution == nil }
    }
}

public struct SaveChangesTool: AgentTool {
    public let workspace: ChangeWorkspace
    public let service: GitHubChangeService
    public let session: ChangeSession
    public let selectedBranch: String
    public let defaultBranch: String
    public let rules: RepoWriteRules
    public let name = "save_changes"
    public init(workspace: ChangeWorkspace, service: GitHubChangeService, session: ChangeSession, selectedBranch: String, defaultBranch: String, rules: RepoWriteRules) {
        self.workspace = workspace; self.service = service; self.session = session; self.selectedBranch = selectedBranch; self.defaultBranch = defaultBranch; self.rules = rules
    }
    public var spec: ToolSpec { ToolSpec(name: name, description: "Save all staged file changes safely. Repository rules decide direct save versus a pull request.", parameters: ["type": "object", "properties": ["title": ["type": "string"], "summary": ["type": "string"]], "required": ["title"]]) }
    public func runningSummary(for arguments: JSONValue) -> String { "Saving changes…" }
    public func approvalRequest(for arguments: JSONValue) async -> ToolApprovalRequest? {
        guard rules.directSave, selectedBranch == defaultBranch, await session.activeReceipt() == nil else { return nil }
        return ToolApprovalRequest(question: "Allow MAIPA-G to save these staged changes directly to \(defaultBranch)?", allowLabel: "Save directly")
    }
    public func approvalAfterOutsideContent(for arguments: JSONValue) async -> ToolApprovalRequest? {
        guard await session.activeReceipt() == nil else { return nil }
        let title = String((arguments.optionalString("title") ?? "Changes").prefix(160))
        return ToolApprovalRequest(question: "Allow MAIPA-G to push staged changes to GitHub (\(title))?", allowLabel: "Save changes")
    }
    public func run(arguments: JSONValue, progress: @escaping @Sendable (String) -> Void) async throws -> ToolOutput {
        if rules.directSave, selectedBranch == defaultBranch, await session.activeReceipt() == nil {
            throw ToolInputError("Saving directly to the default branch needs the person's approval.")
        }
        return try await save(arguments: arguments)
    }
    public func runApproved(arguments: JSONValue, progress: @escaping @Sendable (String) -> Void) async throws -> ToolOutput {
        try await save(arguments: arguments)
    }
    private func save(arguments: JSONValue) async throws -> ToolOutput {
        let title = try arguments.requiredString("title")
        let receipt = try await service.save(workspace, selectedBranch: selectedBranch, defaultBranch: defaultBranch, rules: rules, title: title, body: arguments.optionalString("summary") ?? "Changes made by MAIPA-G.", activeReceipt: await session.activeReceipt())
        await session.record(receipt)
        if let pull = receipt.pullRequest {
            return ToolOutput(forModel: "Saved commit \(receipt.savedCommit) and opened pull request #\(pull.number): \(pull.htmlURL)", summary: "Opened pull request #\(pull.number)", detail: pull.htmlURL)
        }
        return ToolOutput(forModel: "Saved commit \(receipt.savedCommit) directly to \(receipt.branch).", summary: "Saved to \(receipt.branch)")
    }
}

public struct CreateFileTool: AgentTool {
    public let workspace: ChangeWorkspace
    public let authorization: ChangeAuthorization
    public let rules: RepoWriteRules
    public let name = "create_file"
    public init(workspace: ChangeWorkspace, authorization: ChangeAuthorization = ChangeAuthorization(request: ""), rules: RepoWriteRules = RepoWriteRules()) { self.workspace = workspace; self.authorization = authorization; self.rules = rules }
    public var spec: ToolSpec { ToolSpec(name: name, description: "Stage a new UTF-8 text file. The file is not saved to GitHub until save_changes is used.", parameters: ["type": "object", "properties": ["path": ["type": "string"], "content": ["type": "string"]], "required": ["path", "content"]]) }
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
        try await workspace.create(path: path, text: content, buildSetupApproved: true)
        return ToolOutput(forModel: "Staged new file \(path).", summary: "Created \(path)", detail: content)
    }
}

public struct EditFileTool: AgentTool {
    public let workspace: ChangeWorkspace
    public let authorization: ChangeAuthorization
    public let rules: RepoWriteRules
    public let name = "edit_file"
    public init(workspace: ChangeWorkspace, authorization: ChangeAuthorization = ChangeAuthorization(request: ""), rules: RepoWriteRules = RepoWriteRules()) { self.workspace = workspace; self.authorization = authorization; self.rules = rules }
    public var spec: ToolSpec { ToolSpec(name: name, description: "Replace a text file with complete new UTF-8 content, staged until save_changes.", parameters: ["type": "object", "properties": ["path": ["type": "string"], "content": ["type": "string"]], "required": ["path", "content"]]) }
    public func runningSummary(for arguments: JSONValue) -> String { "Editing \(arguments.optionalString("path") ?? "a file")…" }
    public func approvalRequest(for arguments: JSONValue) async -> ToolApprovalRequest? {
        guard let path = arguments.optionalString("path"), ChangeWorkspace.isBuildSetup(RepoWorkspace.normalize(path)),
              !authorization.allows(.buildSetup, path: path) else { return nil }
        return ToolApprovalRequest(question: "Allow MAIPA-G to change the build setup in \(path)?")
    }
    public func run(arguments: JSONValue, progress: @escaping @Sendable (String) -> Void) async throws -> ToolOutput {
        let path = try arguments.requiredString("path")
        if ChangeWorkspace.isBuildSetup(RepoWorkspace.normalize(path)), !rules.permitsBuildSetup(at: path) { throw ToolInputError("Repository rules do not allow changing build setup at \(path).") }
        guard let content = arguments["content"]?.stringValue else { throw ToolInputError("Missing \"content\".") }
        try await workspace.edit(path: path, text: content, buildSetupApproved: true)
        return ToolOutput(forModel: "Staged changes to \(path).", summary: "Edited \(path)", detail: content)
    }
}

public struct DeleteFileTool: AgentTool {
    public let workspace: ChangeWorkspace
    public let authorization: ChangeAuthorization
    public let rules: RepoWriteRules
    public let name = "delete_file"
    public init(workspace: ChangeWorkspace, authorization: ChangeAuthorization = ChangeAuthorization(request: ""), rules: RepoWriteRules = RepoWriteRules()) { self.workspace = workspace; self.authorization = authorization; self.rules = rules }
    public var spec: ToolSpec { ToolSpec(name: name, description: "Stage deletion of a file. MAIPA-G always asks the person before deleting.", parameters: ["type": "object", "properties": ["path": ["type": "string"]], "required": ["path"]]) }
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
