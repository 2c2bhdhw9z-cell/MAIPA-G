import Foundation

public struct CreateRepositoryTool: AgentTool {
    public let github: GitHubClient
    public let name = "create_repository"
    public init(github: GitHubClient) { self.github = github }
    public var spec: ToolSpec {
        ToolSpec(name: name, description: "Create a new GitHub repository after the person approves the exact name and visibility.", parameters: [
            "type": "object",
            "properties": ["name": ["type": "string"], "private": ["type": "boolean"], "description": ["type": "string"]],
            "required": ["name", "private"], "additionalProperties": false,
        ])
    }
    public func runningSummary(for arguments: JSONValue) -> String { "Creating GitHub repository…" }
    public func approvalRequest(for arguments: JSONValue) async -> ToolApprovalRequest? {
        guard let name = arguments.optionalString("name") else { return nil }
        let visibility = arguments["private"]?.boolValue == false ? "public" : "private"
        return ToolApprovalRequest(question: "Create the \(visibility) GitHub repository \(name)?", allowLabel: "Create repository")
    }
    public func run(arguments: JSONValue, progress: @escaping @Sendable (String) -> Void) async throws -> ToolOutput {
        let name = try arguments.requiredString("name")
        let visibility = arguments["private"]?.boolValue == false ? "public" : "private"
        throw ToolApprovalRequired(ToolApprovalRequest(question: "Create the \(visibility) GitHub repository \(name)?", allowLabel: "Create repository"))
    }
    public func runApproved(arguments: JSONValue, progress: @escaping @Sendable (String) -> Void) async throws -> ToolOutput {
        let name = try arguments.requiredString("name")
        let isPrivate = arguments["private"]?.boolValue ?? true
        let repo = try await github.createUserRepository(name: name, isPrivate: isPrivate, description: arguments.optionalString("description") ?? "", autoInit: true)
        return ToolOutput(forModel: "Created \(repo.fullName): \(repo.htmlURL)", summary: "Created \(repo.fullName)", detail: repo.htmlURL)
    }
}

public struct ReadOtherRepositoryFileTool: AgentTool {
    public let github: GitHubClient
    public let repositories: [GitHubRepo]
    public let name = "read_other_repo_file"
    public init(github: GitHubClient, repositories: [GitHubRepo]) { self.github = github; self.repositories = repositories }
    public var spec: ToolSpec {
        ToolSpec(name: name, description: "Read a text file from any connected GitHub repository by repository name and path.", parameters: [
            "type": "object", "properties": ["repository": ["type": "string"], "path": ["type": "string"]],
            "required": ["repository", "path"], "additionalProperties": false,
        ])
    }
    public func runningSummary(for arguments: JSONValue) -> String { "Reading another repository…" }
    public func run(arguments: JSONValue, progress: @escaping @Sendable (String) -> Void) async throws -> ToolOutput {
        let requested = try arguments.requiredString("repository")
        let path = RepoWorkspace.normalize(try arguments.requiredString("path"))
        guard SnapshotStore.isSafeRelativePath(path) else { throw ToolInputError("That repository path is unsafe.") }
        let exact = repositories.first { $0.fullName.caseInsensitiveCompare(requested) == .orderedSame || $0.name.caseInsensitiveCompare(requested) == .orderedSame }
        guard let repo = exact else {
            let close = repositories.map(\.fullName).filter { $0.localizedCaseInsensitiveContains(requested) || requested.localizedCaseInsensitiveContains($0.split(separator: "/").last.map(String.init) ?? $0) }.prefix(5)
            throw ToolInputError("No connected repository exactly matches \(requested)." + (close.isEmpty ? " Available repos: " + repositories.prefix(20).map(\.fullName).joined(separator: ", ") : " Close matches: " + close.joined(separator: ", ")))
        }
        let data = try await github.fileContents(repo.ref, path: path, ref: repo.defaultBranch)
        guard data.count <= 2 * 1024 * 1024, let document = TextFileCodec.decode(data) else { throw ToolInputError("\(path) is not readable text under 2 MB.") }
        return ToolOutput(forModel: "\(repo.fullName)@\(repo.defaultBranch):\(path)\n\(document.text)", summary: "Read \(repo.name)/\(path)", detail: String(document.text.prefix(80_000)))
    }
}

public struct LiveStatusTool: AgentTool {
    public let snapshot: @Sendable () async -> String
    public let name = "introspect"
    public init(snapshot: @escaping @Sendable () async -> String) { self.snapshot = snapshot }
    public var spec: ToolSpec { ToolSpec(name: name, description: "Read MAIPA-G's current connection, saving, computer, and Autonomous job status without exposing secrets.", parameters: ["type": "object", "properties": [:]]) }
    public func runningSummary(for arguments: JSONValue) -> String { "Checking MAIPA-G status…" }
    public func run(arguments: JSONValue, progress: @escaping @Sendable (String) -> Void) async throws -> ToolOutput {
        let value = SensitiveDataRedactor().redact(await snapshot())
        return ToolOutput(forModel: value, summary: "Checked MAIPA-G status", detail: value)
    }
}
