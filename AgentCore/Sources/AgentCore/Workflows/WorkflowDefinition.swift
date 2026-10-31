import Foundation

public enum RepeatLimitBehavior: String, Codable, Sendable, Hashable, CaseIterable {
    case pause
    case continueWorkflow = "continue"
    case fail
}

public enum ParallelJoinPolicy: String, Codable, Sendable, Hashable, CaseIterable {
    case all
    case allSettled
    case any
}

public struct WorkflowNode: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable, Hashable, CaseIterable {
        case agent
        case sequence
        case repeatUntil
        case stopAndAsk
        case parallel
        case watch

        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            switch raw {
            case "agent", "step": self = .agent
            case "sequence": self = .sequence
            case "repeatUntil", "repeat": self = .repeatUntil
            case "stopAndAsk", "ask": self = .stopAndAsk
            case "parallel": self = .parallel
            case "watch": self = .watch
            default:
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Unknown workflow node kind: \(raw)")
                )
            }
        }
    }

    public static let maxTotalSteps = 50
    public static let maxNestingDepth = 8

    public var id: String
    public var kind: Kind
    public var title: String
    public var agentID: String?
    public var instruction: String?
    public var modelID: String?
    public var effortLevel: ThinkingLevel?
    public var children: [WorkflowNode]
    public var maximumIterations: Int?
    public var onMaxIterations: RepeatLimitBehavior?
    public var containsText: String?
    public var successCondition: String?
    public var joinPolicy: ParallelJoinPolicy?
    public var pollIntervalSeconds: Double?
    public var question: String?
    public var options: [String]

    public init(
        id: String = UUID().uuidString.lowercased(),
        kind: Kind,
        title: String,
        agentID: String? = nil,
        instruction: String? = nil,
        modelID: String? = nil,
        effortLevel: ThinkingLevel? = nil,
        children: [WorkflowNode] = [],
        maximumIterations: Int? = nil,
        onMaxIterations: RepeatLimitBehavior? = nil,
        containsText: String? = nil,
        successCondition: String? = nil,
        joinPolicy: ParallelJoinPolicy? = nil,
        pollIntervalSeconds: Double? = nil,
        question: String? = nil,
        options: [String] = []
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.agentID = agentID
        self.instruction = instruction
        self.modelID = modelID
        self.effortLevel = effortLevel
        self.children = children
        self.maximumIterations = maximumIterations
        self.onMaxIterations = onMaxIterations
        self.containsText = containsText
        self.successCondition = successCondition
        self.joinPolicy = joinPolicy
        self.pollIntervalSeconds = pollIntervalSeconds
        self.question = question
        self.options = options
    }

    public var flattenedNodes: [WorkflowNode] { [self] + children.flatMap(\.flattenedNodes) }

    enum CodingKeys: String, CodingKey {
        case id, kind, type, title, name
        case agentID, agentId, agent_id, agent
        case instruction, prompt
        case modelID, modelId, model_id
        case effortLevel, effort_level
        case maximumIterations, maxIterations, max_iterations
        case onMaxIterations, on_max_iterations
        case containsText, contains_text
        case successCondition, success_condition, goal
        case joinPolicy, join_policy
        case pollIntervalSeconds, poll_interval_seconds
        case question, options
        case children, steps, branches
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func firstDecoded<T: Decodable>(_ type: T.Type, _ keys: [CodingKeys]) throws -> T? {
            for key in keys {
                if let value = try c.decodeIfPresent(type, forKey: key) { return value }
            }
            return nil
        }
        id = (try c.decodeIfPresent(String.self, forKey: .id)) ?? UUID().uuidString.lowercased()
        if let decodedKind = try c.decodeIfPresent(Kind.self, forKey: .kind) {
            kind = decodedKind
        } else {
            kind = try c.decode(Kind.self, forKey: .type)
        }
        title = try firstDecoded(String.self, [.title, .name]) ?? id
        agentID = try firstDecoded(String.self, [.agentID, .agentId, .agent_id, .agent])
        instruction = try firstDecoded(String.self, [.instruction, .prompt])
        modelID = try firstDecoded(String.self, [.modelID, .modelId, .model_id])
        effortLevel = try firstDecoded(ThinkingLevel.self, [.effortLevel, .effort_level])
        maximumIterations = try firstDecoded(Int.self, [.maximumIterations, .maxIterations, .max_iterations])
        onMaxIterations = try firstDecoded(RepeatLimitBehavior.self, [.onMaxIterations, .on_max_iterations])
        containsText = try firstDecoded(String.self, [.containsText, .contains_text])
        successCondition = try firstDecoded(String.self, [.successCondition, .success_condition, .goal])
        joinPolicy = try firstDecoded(ParallelJoinPolicy.self, [.joinPolicy, .join_policy])
        pollIntervalSeconds = try firstDecoded(Double.self, [.pollIntervalSeconds, .poll_interval_seconds])
        question = try c.decodeIfPresent(String.self, forKey: .question)
        options = (try c.decodeIfPresent([String].self, forKey: .options)) ?? []
        children = try firstDecoded([WorkflowNode].self, [.children, .steps, .branches]) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(kind, forKey: .kind)
        try c.encode(title, forKey: .title)
        try c.encodeIfPresent(agentID, forKey: .agentID)
        try c.encodeIfPresent(instruction, forKey: .instruction)
        try c.encodeIfPresent(modelID, forKey: .modelID)
        try c.encodeIfPresent(effortLevel, forKey: .effortLevel)
        try c.encode(children, forKey: .children)
        try c.encodeIfPresent(maximumIterations, forKey: .maximumIterations)
        try c.encodeIfPresent(onMaxIterations, forKey: .onMaxIterations)
        try c.encodeIfPresent(containsText, forKey: .containsText)
        try c.encodeIfPresent(successCondition, forKey: .successCondition)
        try c.encodeIfPresent(joinPolicy, forKey: .joinPolicy)
        try c.encodeIfPresent(pollIntervalSeconds, forKey: .pollIntervalSeconds)
        try c.encodeIfPresent(question, forKey: .question)
        try c.encode(options, forKey: .options)
    }

    public static func step(
        _ id: String = UUID().uuidString.lowercased(),
        title: String,
        prompt: String,
        agent: String? = nil,
        modelID: String? = nil,
        effortLevel: ThinkingLevel? = nil
    ) -> WorkflowNode {
        WorkflowNode(id: id, kind: .agent, title: title, agentID: agent, instruction: prompt, modelID: modelID, effortLevel: effortLevel)
    }

    public static func agent(
        _ id: String = UUID().uuidString.lowercased(),
        title: String,
        agent: String,
        instruction: String,
        modelID: String? = nil,
        effortLevel: ThinkingLevel? = nil,
        helpers: [WorkflowNode] = []
    ) -> WorkflowNode {
        WorkflowNode(id: id, kind: .agent, title: title, agentID: agent, instruction: instruction, modelID: modelID, effortLevel: effortLevel, children: helpers)
    }

    public static func sequence(_ id: String = UUID().uuidString.lowercased(), title: String, steps: [WorkflowNode]) -> WorkflowNode {
        WorkflowNode(id: id, kind: .sequence, title: title, children: steps)
    }

    public static func repeatUntil(
        _ id: String = UUID().uuidString.lowercased(),
        title: String,
        maximum: Int,
        goal: String? = nil,
        containsText: String? = nil,
        onMaxIterations: RepeatLimitBehavior? = nil,
        steps: [WorkflowNode]
    ) -> WorkflowNode {
        WorkflowNode(
            id: id,
            kind: .repeatUntil,
            title: title,
            children: steps,
            maximumIterations: maximum,
            onMaxIterations: onMaxIterations,
            containsText: containsText,
            successCondition: goal
        )
    }

    public static func ask(
        _ id: String = UUID().uuidString.lowercased(),
        title: String,
        question: String,
        options: [String] = ["Continue", "Stop"]
    ) -> WorkflowNode {
        WorkflowNode(id: id, kind: .stopAndAsk, title: title, question: question, options: options)
    }

    public static func parallel(
        _ id: String = UUID().uuidString.lowercased(),
        title: String,
        joinPolicy: ParallelJoinPolicy? = nil,
        agents: [WorkflowNode]
    ) -> WorkflowNode {
        WorkflowNode(id: id, kind: .parallel, title: title, children: agents, joinPolicy: joinPolicy)
    }

    public static func watch(
        _ id: String = UUID().uuidString.lowercased(),
        title: String,
        instruction: String,
        containsText: String? = nil,
        goal: String? = nil,
        maximumChecks: Int = 10,
        pollIntervalSeconds: Double = 2,
        agent: String? = nil,
        modelID: String? = nil,
        effortLevel: ThinkingLevel? = nil
    ) -> WorkflowNode {
        WorkflowNode(
            id: id,
            kind: .watch,
            title: title,
            agentID: agent,
            instruction: instruction,
            modelID: modelID,
            effortLevel: effortLevel,
            maximumIterations: max(1, min(maximumChecks, 50)),
            containsText: containsText,
            successCondition: goal,
            pollIntervalSeconds: max(0, min(pollIntervalSeconds, 60))
        )
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
        self.id = id
        self.name = name
        self.summary = summary
        self.steps = steps
        self.isBuiltIn = isBuiltIn
        self.isApproved = isBuiltIn || isApproved
    }

    public var flattenedNodes: [WorkflowNode] { steps.flatMap(\.flattenedNodes) }
    public var allNodes: [WorkflowNode] { flattenedNodes }

    public var maximumDepth: Int {
        func depth(_ nodes: [WorkflowNode], current: Int) -> Int {
            guard !nodes.isEmpty else { return current }
            return nodes.map { node in
                node.children.isEmpty ? current + 1 : depth(node.children, current: current + 1)
            }.max() ?? current
        }
        return depth(steps, current: 0)
    }

    public func validationErrors(agentIDs: Set<String>) -> [String] {
        var errors: [String] = []
        var seen = Set<String>()
        let flat = flattenedNodes
        if flat.count > WorkflowNode.maxTotalSteps {
            errors.append("A workflow may have at most \(WorkflowNode.maxTotalSteps) steps.")
        }
        if maximumDepth > WorkflowNode.maxNestingDepth {
            errors.append("Workflow nesting depth cannot exceed \(WorkflowNode.maxNestingDepth) levels.")
        }

        func check(_ node: WorkflowNode) {
            if node.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                errors.append("Every step needs a non-empty ID.")
            } else if !seen.insert(node.id).inserted {
                errors.append("Step IDs must be unique.")
            }
            if let modelID = node.modelID?.trimmingCharacters(in: .whitespacesAndNewlines),
               modelID == ModelChoice.freeID || modelID.lowercased() == "free" {
                errors.append("\(node.title) cannot target Free AIs; choose a specific model or Auto.")
            }
            switch node.kind {
            case .agent:
                if let explicitAgent = node.agentID, !explicitAgent.isEmpty {
                    if !agentIDs.contains(explicitAgent) {
                        errors.append("\(node.title) needs an agent.")
                    }
                    if let lead = (BuiltInAgents.allIncludingKiroSubagents.first { $0.id == explicitAgent }),
                       node.children.count > lead.maximumHelpers {
                        errors.append("\(node.title) has more than \(lead.maximumHelpers) helpers.")
                    }
                }
                if node.instruction?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                    errors.append("\(node.title) needs instructions.")
                }
                if node.children.contains(where: { $0.kind != .agent }) {
                    errors.append("Agent helpers must be agent steps.")
                }
            case .repeatUntil:
                if !(1...50).contains(node.maximumIterations ?? 0) {
                    errors.append("\(node.title) needs a repeat maximum from 1 to 50.")
                }
                let hasGoal = node.successCondition?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                let hasContains = node.containsText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                if !hasGoal && !hasContains {
                    errors.append("\(node.title) needs a success condition.")
                }
                if node.children.isEmpty {
                    errors.append("\(node.title) needs at least one step.")
                }
            case .stopAndAsk:
                if node.question?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                    errors.append("\(node.title) needs a question.")
                }
            case .parallel:
                if node.children.isEmpty {
                    errors.append("\(node.title) needs at least one helper.")
                }
            case .sequence:
                if node.children.isEmpty {
                    errors.append("\(node.title) needs at least one step.")
                }
            case .watch:
                if node.instruction?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                    errors.append("\(node.title) needs instructions.")
                }
                if !(1...50).contains(node.maximumIterations ?? 10) {
                    errors.append("\(node.title) needs a watch maximum from 1 to 50.")
                }
                if let explicitAgent = node.agentID, !explicitAgent.isEmpty, !agentIDs.contains(explicitAgent) {
                    errors.append("\(node.title) needs an agent.")
                }
            }
            node.children.forEach(check)
        }
        steps.forEach(check)
        if steps.isEmpty { errors.append("A workflow needs at least one step.") }
        return Array(Set(errors)).sorted()
    }

    /// Interpolates `{{stepId.output}}` and `{{workflow.prompt}}` / `{{request}}` with explicit
    /// `<workflow_step_output>` and `<workflow_prompt>` untrusted-data boundaries.
    public static func interpolateTemplate(
        _ raw: String,
        outputsByStepID: [String: String],
        request: String
    ) -> String {
        guard raw.contains("{{") else { return raw }
        var result = raw
        let wrappedPrompt = "<workflow_prompt>\n\(request)\n</workflow_prompt>"
        result = result.replacingOccurrences(of: "{{workflow.prompt}}", with: wrappedPrompt)
        result = result.replacingOccurrences(of: "{{request}}", with: wrappedPrompt)

        let pattern = #"\{\{\s*([A-Za-z0-9_.\-]+)\.output\s*\}\}"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return result }
        let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed()
        for match in matches {
            guard match.numberOfRanges >= 2,
                  let fullRange = Range(match.range(at: 0), in: result),
                  let stepRange = Range(match.range(at: 1), in: result) else { continue }
            let stepID = String(result[stepRange])
            let body = outputsByStepID[stepID] ?? ""
            let bounded = "<workflow_step_output step=\"\(stepID)\">\n\(body)\n</workflow_step_output>"
            result.replaceSubrange(fullRange, with: bounded)
        }
        return result
    }
}

public enum WorkflowDraftBuilder {
    public static func generationPrompt(description: String, agents: [AgentDefinition]) -> String {
        let catalogue = agents.map { "\($0.id): \($0.name) — \($0.summary)" }.joined(separator: "\n")
        return """
        Translate the workflow description into one typed workflow JSON object. Return JSON only, with exactly these top-level keys: id, name, summary, steps, isBuiltIn, isApproved. Set id to "generated", isBuiltIn and isApproved to false. Every step has id, kind, title, agentID, instruction, children, maximumIterations, onMaxIterations, containsText, successCondition, joinPolicy, question, and options. kind is one of step, agent, sequence, repeat, parallel, watch, stopAndAsk. At most 50 total steps and 8 nesting levels. Steps may reference earlier outputs via {{stepId.output}} and optionally specify modelID and effortLevel.

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
