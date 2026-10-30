import Foundation

/// Loads repository instructions only when the model needs them. The standing prompt receives
/// paths and scopes, not up to hundreds of thousands of characters of rule text.
public struct LoadRepoRulesTool: AgentTool {
    public let documents: [RepoRuleDocument]
    public let name = "load_repo_rules"

    public init(documents: [RepoRuleDocument]) { self.documents = documents }

    public var spec: ToolSpec {
        ToolSpec(
            name: name,
            description: "Read the repository rule documents that apply to a file or the whole task.",
            parameters: [
                "type": "object",
                "properties": ["path": ["type": "string", "description": "Optional repository file path whose rules are needed."]],
                "additionalProperties": false,
            ]
        )
    }

    public func runningSummary(for arguments: JSONValue) -> String { "Loading repository rules…" }

    public func run(arguments: JSONValue, progress: @escaping @Sendable (String) -> Void) async throws -> ToolOutput {
        let path = arguments.optionalString("path").map(RepoWorkspace.normalize)
        let matches = documents.filter { document in path.map(document.applies) ?? document.scope.isEmpty }
        let selected = matches.isEmpty ? documents.filter { $0.scope.isEmpty } : matches
        let text = selected.map {
            "--- \($0.path) (scope: \($0.scope.isEmpty ? "whole repository" : $0.scope)) ---\n\(String($0.text.prefix(20_000)))"
        }.joined(separator: "\n\n")
        return ToolOutput(
            forModel: text.isEmpty ? "No repository rule document applies." : text,
            summary: "Loaded \(selected.count) repository rule document\(selected.count == 1 ? "" : "s")",
            detail: text
        )
    }
}
