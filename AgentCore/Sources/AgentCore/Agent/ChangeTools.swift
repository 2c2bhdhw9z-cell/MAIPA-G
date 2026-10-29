import Foundation

public struct ChangeAuthorization: Sendable, Hashable {
    public var deletion: Bool
    public var buildSetup: Bool
    public init(deletion: Bool, buildSetup: Bool) {
        self.deletion = deletion; self.buildSetup = buildSetup
    }
    public init(request: String) {
        let text = request.lowercased()
        deletion = text.contains("delete") || text.contains("remove the file") || text.contains("remove files") || text.contains("just get on with it")
        buildSetup = text.contains("workflow") || text.contains("build setup") || text.contains("package.swift") || text.contains("package.json") || text.contains("project.yml") || text.contains("just get on with it")
    }
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
    public func run(arguments: JSONValue, progress: @escaping @Sendable (String) -> Void) async throws -> ToolOutput {
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
    public let name = "create_file"
    public init(workspace: ChangeWorkspace, authorization: ChangeAuthorization = ChangeAuthorization(request: "")) { self.workspace = workspace; self.authorization = authorization }
    public var spec: ToolSpec { ToolSpec(name: name, description: "Stage a new UTF-8 text file. The file is not saved to GitHub until save_changes is used.", parameters: ["type": "object", "properties": ["path": ["type": "string"], "content": ["type": "string"]], "required": ["path", "content"]]) }
    public func runningSummary(for arguments: JSONValue) -> String { "Creating \(arguments.optionalString("path") ?? "a file")…" }
    public func approvalRequest(for arguments: JSONValue) async -> ToolApprovalRequest? {
        guard !authorization.buildSetup, let path = arguments.optionalString("path"), ChangeWorkspace.isBuildSetup(RepoWorkspace.normalize(path)) else { return nil }
        return ToolApprovalRequest(question: "Allow MAIPA-G to add the build-setup file \(path)?")
    }
    public func run(arguments: JSONValue, progress: @escaping @Sendable (String) -> Void) async throws -> ToolOutput {
        let path = try arguments.requiredString("path")
        guard let content = arguments["content"]?.stringValue else { throw ToolInputError("Missing \"content\".") }
        try await workspace.create(path: path, text: content, buildSetupApproved: true)
        return ToolOutput(forModel: "Staged new file \(path).", summary: "Created \(path)", detail: content)
    }
}

public struct EditFileTool: AgentTool {
    public let workspace: ChangeWorkspace
    public let authorization: ChangeAuthorization
    public let name = "edit_file"
    public init(workspace: ChangeWorkspace, authorization: ChangeAuthorization = ChangeAuthorization(request: "")) { self.workspace = workspace; self.authorization = authorization }
    public var spec: ToolSpec { ToolSpec(name: name, description: "Replace a text file with complete new UTF-8 content, staged until save_changes.", parameters: ["type": "object", "properties": ["path": ["type": "string"], "content": ["type": "string"]], "required": ["path", "content"]]) }
    public func runningSummary(for arguments: JSONValue) -> String { "Editing \(arguments.optionalString("path") ?? "a file")…" }
    public func approvalRequest(for arguments: JSONValue) async -> ToolApprovalRequest? {
        guard !authorization.buildSetup, let path = arguments.optionalString("path"), ChangeWorkspace.isBuildSetup(RepoWorkspace.normalize(path)) else { return nil }
        return ToolApprovalRequest(question: "Allow MAIPA-G to change the build setup in \(path)?")
    }
    public func run(arguments: JSONValue, progress: @escaping @Sendable (String) -> Void) async throws -> ToolOutput {
        let path = try arguments.requiredString("path")
        guard let content = arguments["content"]?.stringValue else { throw ToolInputError("Missing \"content\".") }
        try await workspace.edit(path: path, text: content, buildSetupApproved: true)
        return ToolOutput(forModel: "Staged changes to \(path).", summary: "Edited \(path)", detail: content)
    }
}

public struct DeleteFileTool: AgentTool {
    public let workspace: ChangeWorkspace
    public let authorization: ChangeAuthorization
    public let name = "delete_file"
    public init(workspace: ChangeWorkspace, authorization: ChangeAuthorization = ChangeAuthorization(request: "")) { self.workspace = workspace; self.authorization = authorization }
    public var spec: ToolSpec { ToolSpec(name: name, description: "Stage deletion of a file. MAIPA-G always asks the person before deleting.", parameters: ["type": "object", "properties": ["path": ["type": "string"]], "required": ["path"]]) }
    public func runningSummary(for arguments: JSONValue) -> String { "Deleting \(arguments.optionalString("path") ?? "a file")…" }
    public func approvalRequest(for arguments: JSONValue) async -> ToolApprovalRequest? {
        guard !authorization.deletion else { return nil }
        let path = arguments.optionalString("path") ?? "this file"
        return ToolApprovalRequest(question: "Allow MAIPA-G to delete \(path)?")
    }
    public func run(arguments: JSONValue, progress: @escaping @Sendable (String) -> Void) async throws -> ToolOutput {
        let path = try arguments.requiredString("path")
        try await workspace.delete(path: path, approved: true)
        return ToolOutput(forModel: "Staged deletion of \(path).", summary: "Deleted \(path)")
    }
}
