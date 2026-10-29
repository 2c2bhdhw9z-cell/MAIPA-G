import Foundation

public struct WorkflowNode: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable, CaseIterable { case agent, sequence, repeatUntil, stopAndAsk, parallel }

    public var id: String
    public var kind: Kind
    public var title: String
    public var agentID: String?
    public var instruction: String?
    public var children: [WorkflowNode]
    public var maximumIterations: Int?
    public var successCondition: String?
    public var question: String?
    public var options: [String]

    public init(
        id: String = UUID().uuidString.lowercased(), kind: Kind, title: String,
        agentID: String? = nil, instruction: String? = nil, children: [WorkflowNode] = [],
        maximumIterations: Int? = nil, successCondition: String? = nil,
        question: String? = nil, options: [String] = []
    ) {
        self.id = id; self.kind = kind; self.title = title; self.agentID = agentID
        self.instruction = instruction; self.children = children
        self.maximumIterations = maximumIterations; self.successCondition = successCondition
        self.question = question; self.options = options
    }

    public static func agent(_ id: String = UUID().uuidString.lowercased(), title: String, agent: String, instruction: String) -> WorkflowNode {
        WorkflowNode(id: id, kind: .agent, title: title, agentID: agent, instruction: instruction)
    }

    public static func repeatUntil(_ id: String = UUID().uuidString.lowercased(), title: String, maximum: Int, goal: String, steps: [WorkflowNode]) -> WorkflowNode {
        WorkflowNode(id: id, kind: .repeatUntil, title: title, children: steps, maximumIterations: maximum, successCondition: goal)
    }

    public static func ask(_ id: String = UUID().uuidString.lowercased(), title: String, question: String, options: [String]) -> WorkflowNode {
        WorkflowNode(id: id, kind: .stopAndAsk, title: title, question: question, options: options)
    }

    public static func parallel(_ id: String = UUID().uuidString.lowercased(), title: String, agents: [WorkflowNode]) -> WorkflowNode {
        WorkflowNode(id: id, kind: .parallel, title: title, children: agents)
    }
}

public struct WorkflowDefinition: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var summary: String
    public var steps: [WorkflowNode]
    public var isBuiltIn: Bool
    public var isApproved: Bool

    public init(id: String, name: String, summary: String, steps: [WorkflowNode], isBuiltIn: Bool = false, isApproved: Bool = false) {
        self.id = id; self.name = name; self.summary = summary; self.steps = steps
        self.isBuiltIn = isBuiltIn; self.isApproved = isBuiltIn || isApproved
    }

    public func validationErrors(agentIDs: Set<String>) -> [String] {
        var errors: [String] = []
        var seen = Set<String>()
        func check(_ node: WorkflowNode) {
            if !seen.insert(node.id).inserted { errors.append("Step IDs must be unique.") }
            switch node.kind {
            case .agent:
                if node.agentID.map(agentIDs.contains) != true { errors.append("\(node.title) needs an agent.") }
                if node.instruction?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false { errors.append("\(node.title) needs instructions.") }
            case .repeatUntil:
                if !(1...50).contains(node.maximumIterations ?? 0) { errors.append("\(node.title) needs a repeat maximum from 1 to 50.") }
                if node.children.isEmpty { errors.append("\(node.title) needs at least one step.") }
            case .stopAndAsk:
                if node.question?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false { errors.append("\(node.title) needs a question.") }
            case .parallel:
                if node.children.isEmpty { errors.append("\(node.title) needs at least one helper.") }
                if node.children.contains(where: { $0.kind != .agent }) { errors.append("Parallel children must be agent steps.") }
            case .sequence:
                if node.children.isEmpty { errors.append("\(node.title) needs at least one step.") }
            }
            node.children.forEach(check)
        }
        steps.forEach(check)
        if steps.isEmpty { errors.append("A workflow needs at least one step.") }
        return Array(Set(errors)).sorted()
    }
}

public enum WorkflowDraftBuilder {
    /// Produces a real, editable typed draft from plain language. The app always presents the
    /// resulting steps for explicit approval before execution.
    public static func initialDraft(description: String, id: String = "custom:\(UUID().uuidString.lowercased())") -> WorkflowDefinition {
        let text = description.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased()
        var steps: [WorkflowNode] = [.agent(title: "Plan the work", agent: "planner", instruction: text)]
        if lower.contains("design") || lower.contains("feature") {
            steps.append(.agent(title: "Design it", agent: "designer", instruction: "Design the approved request."))
            steps.append(.agent(title: "Check the design", agent: "design-checker", instruction: "Check the design against the request."))
        }
        if lower.contains("review") && lower.contains("two") {
            steps.append(.parallel(title: "Independent reviews", agents: [
                .agent(title: "Code review", agent: "code-checker", instruction: "Review the completed work."),
                .agent(title: "Second opinion", agent: "second-opinion", instruction: "Review independently with a different model."),
            ]))
            steps.append(.agent(title: "Combine reviews", agent: "review-combiner", instruction: "Combine the independent reviews."))
        }
        return WorkflowDefinition(id: id, name: text.isEmpty ? "New workflow" : String(text.prefix(60)), summary: text, steps: steps, isApproved: false)
    }
}
