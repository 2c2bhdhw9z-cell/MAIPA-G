import Foundation

/// Reads the exact immutable version inserted by Files' “Add to chat” action.
public struct ReadRepoFileTool: AgentTool {
    public let github: GitHubClient
    public let name = "read_repo_file"

    public init(github: GitHubClient) { self.github = github }

    public var spec: ToolSpec {
        ToolSpec(name: name, description: "Read a text file at a repository commit SHA (7 to 40 hex characters). Use this for a Repo file reference in the person's message.", parameters: [
            "type": "object",
            "properties": [
                "repository": ["type": "string", "description": "owner/name"],
                "commit": ["type": "string", "description": "Git commit SHA (7 to 40 hex characters)"],
                "path": ["type": "string"],
            ],
            "required": ["repository", "commit", "path"],
            "additionalProperties": false,
        ])
    }

    public func runningSummary(for arguments: JSONValue) -> String { "Reading \(arguments.optionalString("path") ?? "a referenced file")…" }

    public func run(arguments: JSONValue, progress: @escaping @Sendable (String) -> Void) async throws -> ToolOutput {
        guard let repo = RepoRef(fullName: try arguments.requiredString("repository")) else { throw ToolInputError("The repository must be owner/name.") }
        let commit = try arguments.requiredString("commit").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard (7...40).contains(commit.count), commit.allSatisfy({ $0.isHexDigit }) else { throw ToolInputError("The file reference needs a 7- to 40-character hexadecimal commit SHA.") }
        let path = try ChangeWorkspace.safe(try arguments.requiredString("path"))
        let data = try await github.fileContents(repo, path: path, ref: commit)
        guard data.count <= 1_000_000, let text = String(data: data, encoding: .utf8) else { throw ToolInputError("That referenced file is not UTF-8 text under 1 MB.") }
        return ToolOutput(forModel: "\(repo.fullName)@\(commit):\(path)\n\(text)", summary: "Read \(path) at \(commit.prefix(7))", detail: String(text.prefix(40_000)))
    }
}
