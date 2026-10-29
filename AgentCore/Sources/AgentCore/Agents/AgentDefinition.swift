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
/// use `custom:<uuid>` so they can be referenced safely from saved workflows.
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
        "create_file", "edit_file", "delete_file", "save_changes", "undo_changes", "run_shell",
        "dispatch_workflow", "create_pull_request", "merge_pull_request", "close_pull_request",
        "reply_to_review_comment", "submit_pull_request_review",
    ]

    public func permits(tool name: String) -> Bool {
        guard allowedTools.contains(name) else { return false }
        if behavior == .reportOnly || behavior == .review {
            return !Self.mutatingTools.contains(name)
        }
        return true
    }

    public func prompt(task: String) -> String {
        """
        You are the \(name) agent.
        \(instructions)

        Stay inside this role. \(behavior == .reportOnly || behavior == .review ? "Inspect and report only. Do not change files, save changes, start builds, or open pull requests." : "You may make only the changes needed for this role.")
        Task: \(task)
        """
    }
}
