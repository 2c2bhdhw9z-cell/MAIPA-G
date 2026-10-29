import Foundation

public enum SpecStage: String, Codable, Sendable, CaseIterable, Hashable {
    case requirements
    case design
    case checkedDesign
    case tasks
    case execution
    case completed

    public var title: String {
        switch self {
        case .requirements: return "Requirements"
        case .design: return "Design"
        case .checkedDesign: return "Checked design"
        case .tasks: return "Tasks"
        case .execution: return "Build"
        case .completed: return "Done"
        }
    }

    public var next: SpecStage? {
        switch self {
        case .requirements: return .design
        case .design: return .checkedDesign
        case .checkedDesign: return .tasks
        case .tasks: return .execution
        case .execution: return .completed
        case .completed: return nil
        }
    }
}

public struct SpecTask: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var title: String
    public var isComplete: Bool
    public var completedAt: Date?

    public init(id: UUID = UUID(), title: String, isComplete: Bool = false, completedAt: Date? = nil) {
        self.id = id
        self.title = title
        self.isComplete = isComplete
        self.completedAt = completedAt
    }
}

public enum SpecFailure: Error, Sendable, Equatable, CustomStringConvertible {
    case emptyTitle
    case emptyArtifact(SpecStage)
    case stageOutOfOrder(expected: SpecStage, received: SpecStage)
    case taskNotFound

    public var description: String {
        switch self {
        case .emptyTitle: return "Give the spec a name."
        case .emptyArtifact(let stage): return "The \(stage.title.lowercased()) can't be empty."
        case .stageOutOfOrder(let expected, let received): return "Approve \(expected.title.lowercased()) before \(received.title.lowercased())."
        case .taskNotFound: return "That task is no longer in this spec."
        }
    }
}

public enum SpecWorkflows {
    public static func draft(_ stage: SpecStage, context: String) -> WorkflowDefinition {
        let node: WorkflowNode
        switch stage {
        case .requirements:
            node = .agent("spec.requirements", title: "Write requirements", agent: "planner", instruction: "Write complete, testable requirements for this spec. Return only the requirements document in Markdown.\n\n\(context)")
        case .design:
            node = .agent("spec.design", title: "Write design", agent: "designer", instruction: "Design the approved requirements. Return only the design document in Markdown.\n\n\(context)")
        case .checkedDesign:
            node = .agent("spec.design-check", title: "Check design", agent: "design-checker", instruction: "Check and correct the design against every approved requirement. Return the complete corrected design document in Markdown.\n\n\(context)")
        case .tasks:
            node = .agent("spec.tasks", title: "Write tasks", agent: "planner", instruction: "Turn the approved requirements and checked design into an ordered Markdown checklist using '- [ ]' for every implementation task. Return only the checklist.\n\n\(context)")
        case .execution, .completed:
            node = .agent("spec.execute", title: "Implement task", agent: "coder", instruction: context)
        }
        return WorkflowDefinition(id: "spec-\(stage.rawValue):\(UUID().uuidString.lowercased())", name: stage.title, summary: "Build this stage of the project spec.", steps: [node], isApproved: true)
    }

    public static func execute(task: SpecTask, context: String) -> WorkflowDefinition {
        WorkflowDefinition(
            id: "spec-task:\(task.id.uuidString.lowercased())",
            name: task.title,
            summary: "Implement and independently check one approved spec task.",
            steps: [
                .repeatUntil("spec.task.repair-loop", title: "Implement and verify", maximum: 3, goal: "The approved spec task is fully implemented and every relevant check passes with no unresolved defect.", steps: [
                    .agent("spec.task.build", title: "Implement or repair", agent: "coder", instruction: "Implement this approved spec task completely. On later rounds, use the checker's prior findings to repair every defect. Run the relevant checks.\n\nTask: \(task.title)\n\n\(context)"),
                    .agent("spec.task.check", title: "Check", agent: "code-checker", instruction: "Independently inspect the implementation and verification. Do not edit. End with GOAL_MET only when the task is complete, every relevant check passes, and no defect remains; otherwise end with GOAL_NOT_MET and list exact repair findings."),
                ]),
            ],
            isApproved: true
        )
    }
}
