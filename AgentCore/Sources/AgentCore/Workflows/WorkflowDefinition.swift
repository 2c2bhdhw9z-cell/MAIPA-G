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

    public var flattenedNodes: [WorkflowNode] { [self] + children.flatMap(\.flattenedNodes) }

    public static func agent(_ id: String = UUID().uuidString.lowercased(), title: String, agent: String, instruction: String, helpers: [WorkflowNode] = []) -> WorkflowNode {
        WorkflowNode(id: id, kind: .agent, title: title, agentID: agent, instruction: instruction, children: helpers)
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

    public var flattenedNodes: [WorkflowNode] { steps.flatMap(\.flattenedNodes) }

    public func validationErrors(agentIDs: Set<String>) -> [String] {
        var errors: [String] = []
        var seen = Set<String>()
        func check(_ node: WorkflowNode) {
            if !seen.insert(node.id).inserted { errors.append("Step IDs must be unique.") }
            switch node.kind {
            case .agent:
                if node.agentID.map(agentIDs.contains) != true { errors.append("\(node.title) needs an agent.") }
                if node.instruction?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false { errors.append("\(node.title) needs instructions.") }
                if let leadID = node.agentID, let lead = (BuiltInAgents.all.first { $0.id == leadID }), node.children.count > lead.maximumHelpers {
                    errors.append("\(node.title) has more than \(lead.maximumHelpers) helpers.")
                }
                if node.children.contains(where: { $0.kind != .agent }) { errors.append("Agent helpers must be agent steps.") }
            case .repeatUntil:
                if !(1...50).contains(node.maximumIterations ?? 0) { errors.append("\(node.title) needs a repeat maximum from 1 to 50.") }
                if node.successCondition?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false { errors.append("\(node.title) needs a success condition.") }
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
    public static func generationPrompt(description: String, agents: [AgentDefinition]) -> String {
        let catalogue = agents.map { "\($0.id): \($0.name) — \($0.summary)" }.joined(separator: "\n")
        return """
        Translate the workflow description into one typed workflow JSON object. Return JSON only, with exactly these top-level keys: id, name, summary, steps, isBuiltIn, isApproved. Set id to "generated", isBuiltIn and isApproved to false. Every step has id, kind, title, agentID, instruction, children, maximumIterations, successCondition, question, and options. kind is one of agent, sequence, repeatUntil, stopAndAsk, parallel. Use only listed agent IDs. Repeat limits must be finite integers from 1 through 50. Parallel children must all be agent steps. Preserve checklists as ordered agent or sequence steps and include builders, questions, repeats, and custom agents when the description asks for them.

        Available agents:
        \(catalogue)

        Description:
        \(description)
        """
    }

    public static func generatedDraft(from response: String, agentIDs: Set<String>, id: String = "custom:\(UUID().uuidString.lowercased())") throws -> WorkflowDefinition {
        guard let start = response.firstIndex(of: "{"), let end = response.lastIndex(of: "}"), start <= end else {
            throw ToolInputError("Workflow maker did not return a typed workflow draft.")
        }
        let data = Data(response[start...end].utf8)
        var draft: WorkflowDefinition
        do { draft = try JSONCoding.decoder().decode(WorkflowDefinition.self, from: data) }
        catch { throw ToolInputError("Workflow maker returned invalid workflow JSON: \(error)") }
        draft.id = id
        draft.isBuiltIn = false
        draft.isApproved = false
        let errors = draft.validationErrors(agentIDs: agentIDs)
        guard errors.isEmpty else { throw ToolInputError(errors.joined(separator: " ")) }
        return draft
    }

    /// A blank typed draft used only by the manual editor when no AI draft has been requested.
    public static func initialDraft(description: String, id: String = "custom:\(UUID().uuidString.lowercased())") -> WorkflowDefinition {
        let text = description.trimmingCharacters(in: .whitespacesAndNewlines)
        return WorkflowDefinition(id: id, name: text.isEmpty ? "New workflow" : String(text.prefix(60)), summary: text, steps: [
            .agent(title: "Plan the work", agent: "planner", instruction: text.isEmpty ? "Describe this step." : text),
        ], isApproved: false)
    }
}
