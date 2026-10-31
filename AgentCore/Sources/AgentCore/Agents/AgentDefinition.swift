import Foundation

public enum AgentModelPolicy: String, Codable, Sendable, Hashable, CaseIterable {
    case automatic
    case strong
    case fast
    case differentFromPrimary
}

public enum AgentBehavior: String, Codable, Sendable, Hashable, CaseIterable {
    case reportOnly
    case changesAllowed
    case review
    case pullRequest
    case feedback
    case build
}

/// A complete, portable description of one agent. Built-ins use stable string IDs; custom agents
/// use `custom:<uuid>` and repository `.kiro/agents` definitions use `repo:<slug>`.
public struct AgentDefinition: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var summary: String
    public var instructions: String
    public var allowedTools: [String]
    public var difficulty: TaskDifficulty
    public var modelPolicy: AgentModelPolicy
    public var behavior: AgentBehavior
    public var maximumHelpers: Int
    public var isBuiltIn: Bool

    public init(
        id: String,
        name: String,
        summary: String,
        instructions: String,
        allowedTools: [String],
        difficulty: TaskDifficulty,
        modelPolicy: AgentModelPolicy = .automatic,
        behavior: AgentBehavior,
        maximumHelpers: Int = 0,
        isBuiltIn: Bool = false
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.instructions = instructions
        self.allowedTools = Array(Set(allowedTools)).sorted()
        self.difficulty = difficulty
        self.modelPolicy = modelPolicy
        self.behavior = behavior
        self.maximumHelpers = max(0, min(maximumHelpers, 6))
        self.isBuiltIn = isBuiltIn
    }

    public static let mutatingTools: Set<String> = [
        "create_file", "edit_file", "append_file", "delete_file", "save_changes", "undo_changes",
        "run_shell", "run_command", "computer_task", "sync_staged_to_computer",
        "write_workstation_file", "create_custom_agent", "save_workflow_definition", "run_workflow", "update_workflow",
        "dispatch_workflow", "create_pull_request", "merge_pull_request", "close_pull_request",
        "reply_to_review_comment", "submit_pull_request_review", "create_repository",
    ]

    public func permits(tool name: String) -> Bool {
        if name == "launch_helpers" { return maximumHelpers > 0 }
        let matchesAllowed: Bool = {
            if allowedTools.contains("*") || allowedTools.contains(name) { return true }
            if allowedTools.contains("mcp_*") && name.hasPrefix("mcp_") { return true }
            return false
        }()
        guard matchesAllowed else { return false }
        if behavior == .reportOnly || behavior == .review {
            return !Self.mutatingTools.contains(name)
        }
        return true
    }

    public func prompt(task: String) -> String {
        """
        You are the \(name) sub-agent.
        \(instructions)

        Stay strictly inside this role. \(behavior == .reportOnly || behavior == .review ? "Inspect and report only. Do not modify files, save changes, run mutating commands, start builds, or open pull requests." : "Make only the focused changes and checks required for this task.")
        Task: \(task)
        """
    }
}

/// Loads repository-local `.kiro/agents/*.json` and `.kiro/agents/*.md` sub-agent definitions safely
/// as untrusted data-scoped roles (never granting mutating privileges beyond the main chat's own tools).
public enum RepoAgentLoader {
    public static func loadAgents(from workspace: RepoWorkspace) async -> [AgentDefinition] {
        guard let tree = try? await workspace.tree() else { return [] }
        let entries = tree.entries.filter { entry in
            let lower = entry.path.lowercased()
            return entry.isFile
                && lower.hasPrefix(".kiro/agents/")
                && (lower.hasSuffix(".json") || lower.hasSuffix(".md"))
        }.prefix(24)
        var loaded: [AgentDefinition] = []
        for entry in entries {
            guard case .text(let content, _) = try? await workspace.readFile(entry.path) else { continue }
            if entry.path.lowercased().hasSuffix(".json"),
               let parsed = parseJSONAgent(content, filePath: entry.path) {
                loaded.append(parsed)
            } else if entry.path.lowercased().hasSuffix(".md"),
                      let parsed = parseMarkdownAgent(content, filePath: entry.path) {
                loaded.append(parsed)
            }
        }
        return loaded
    }

    static func parseJSONAgent(_ raw: String, filePath: String) -> AgentDefinition? {
        guard let json = JSONValue.parse(Data(raw.utf8)), json.objectValue != nil else { return nil }
        let slug = URL(fileURLWithPath: filePath).deletingPathExtension().lastPathComponent
        let rawID = json["id"]?.stringValue ?? json["name"]?.stringValue ?? slug
        let cleanSlug = sanitizeSlug(rawID)
        guard !cleanSlug.isEmpty else { return nil }
        let displayName = json["displayName"]?.stringValue ?? json["name"]?.stringValue ?? slug
        let summary = json["description"]?.stringValue ?? json["summary"]?.stringValue ?? "Repository sub-agent from \(filePath)"
        let prompt = json["prompt"]?.stringValue ?? json["instructions"]?.stringValue ?? summary
        let rawTools = (json["tools"]?.arrayValue ?? json["allowedTools"]?.arrayValue)?.compactMap(\.stringValue)
        let readOnly = (json["readOnly"]?.boolValue == true) || (json["behavior"]?.stringValue == "reportOnly") || (json["behavior"]?.stringValue == "review")
        let defaultInspect = BuiltInAgents.inspectToolNames
        let tools = rawTools?.isEmpty == false ? rawTools! : (readOnly ? defaultInspect : BuiltInAgents.generalExecutionToolNames)
        return AgentDefinition(
            id: "repo:\(cleanSlug)",
            name: String(displayName.prefix(60)),
            summary: String(summary.prefix(200)),
            instructions: String(prompt.prefix(8_000)),
            allowedTools: tools,
            difficulty: .normal,
            modelPolicy: .automatic,
            behavior: readOnly ? .reportOnly : .changesAllowed,
            maximumHelpers: 0,
            isBuiltIn: false
        )
    }

    static func parseMarkdownAgent(_ raw: String, filePath: String) -> AgentDefinition? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let slug = sanitizeSlug(URL(fileURLWithPath: filePath).deletingPathExtension().lastPathComponent)
        guard !slug.isEmpty else { return nil }
        var name = slug.replacingOccurrences(of: "-", with: " ").capitalized
        var summary = "Repository sub-agent from \(filePath)"
        var body = trimmed

        // Parse optional YAML frontmatter (`---\nname: ...\ndescription: ...\n---`)
        if trimmed.hasPrefix("---") {
            let lines = trimmed.components(separatedBy: "\n")
            if let endIdx = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) {
                var readOnly = true
                for headerLine in lines[1..<endIdx] {
                    let parts = headerLine.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                    guard parts.count == 2 else { continue }
                    let key = parts[0].lowercased()
                    let val = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                    if key == "name", !val.isEmpty { name = val }
                    else if key == "description" || key == "summary", !val.isEmpty { summary = val }
                    else if key == "tools" && (val.contains("edit") || val.contains("write") || val.contains("run_command") || val.contains("*")) {
                        readOnly = false
                    }
                }
                body = lines[(endIdx + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                return AgentDefinition(
                    id: "repo:\(slug)",
                    name: String(name.prefix(60)),
                    summary: String(summary.prefix(200)),
                    instructions: String((body.isEmpty ? summary : body).prefix(8_000)),
                    allowedTools: readOnly ? BuiltInAgents.inspectToolNames : BuiltInAgents.generalExecutionToolNames,
                    difficulty: .normal,
                    modelPolicy: .automatic,
                    behavior: readOnly ? .reportOnly : .changesAllowed,
                    maximumHelpers: 0,
                    isBuiltIn: false
                )
            }
        }

        return AgentDefinition(
            id: "repo:\(slug)",
            name: String(name.prefix(60)),
            summary: String(summary.prefix(200)),
            instructions: String(body.prefix(8_000)),
            allowedTools: BuiltInAgents.inspectToolNames,
            difficulty: .normal,
            modelPolicy: .automatic,
            behavior: .reportOnly,
            maximumHelpers: 0,
            isBuiltIn: false
        )
    }

    private static func sanitizeSlug(_ input: String) -> String {
        let lower = input.lowercased()
        let cleaned = lower.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_" {
                return Character(scalar)
            }
            return "-"
        }
        return String(cleaned).trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
    }
}
