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
            description: "Read the repository rule documents and Kiro steering files that apply to a file or the whole task, or one steering file by name (Kiro's #name).",
            parameters: [
                "type": "object",
                "properties": [
                    "path": ["type": "string", "description": "Optional repository file path whose rules are needed (includes fileMatch steering for it)."],
                    "name": ["type": "string", "description": "Optional steering file name, like \"api-standards\", for manual or auto steering."],
                ],
                "additionalProperties": false,
            ]
        )
    }

    public func runningSummary(for arguments: JSONValue) -> String { "Loading repository rules…" }

    public func run(arguments: JSONValue, progress: @escaping @Sendable (String) -> Void) async throws -> ToolOutput {
        let path = arguments.optionalString("path").map(RepoWorkspace.normalize)
        let name = arguments.optionalString("name").map { name -> String in
            let lower = name.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "# "))
            return lower.hasSuffix(".md") ? String(lower.dropLast(3)) : lower
        }
        // Kiro inclusion modes: always-on documents by scope, fileMatch steering for a matching
        // path, and manual/auto steering only when named.
        let alwaysOn = documents.filter { if case .always = $0.inclusion { return true } else { return false } }
        let selected: [RepoRuleDocument]
        if let name, !name.isEmpty {
            selected = documents.filter { $0.isReferenced(by: [name]) }
        } else {
            let matches = alwaysOn.filter { document in path.map(document.applies) ?? document.scope.isEmpty }
                + (path.map { p in documents.filter { $0.matchesFile(p) } } ?? [])
            selected = matches.isEmpty ? alwaysOn.filter { $0.scope.isEmpty } : matches
        }
        let text = selected.map {
            "--- \($0.path) (\($0.inclusionLabel)) ---\n\(String($0.text.prefix(20_000)))"
        }.joined(separator: "\n\n")
        return ToolOutput(
            forModel: text.isEmpty ? (name.map { "No steering file named \($0)." } ?? "No repository rule document applies.") : text,
            summary: "Loaded \(selected.count) repository rule document\(selected.count == 1 ? "" : "s")",
            detail: text
        )
    }
}
