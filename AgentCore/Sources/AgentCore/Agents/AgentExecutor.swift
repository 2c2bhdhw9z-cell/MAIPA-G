import Foundation

public struct AgentInvocation: Sendable {
    public var definition: AgentDefinition
    public var task: String
    public var context: String
    public var avoidModel: String?
    /// Remaining aggregate workflow allowance for this paid agent operation.
    public var spendLimit: Double?
    /// Opaque, checkpointed chat state for resuming one exact paused agent/tool call.
    public var resumeState: JSONValue?
    public var answer: String?
    /// Scheduler capabilities supplied only to this invocation. Helper children receive none.
    public var tools: [any AgentTool]

    public init(definition: AgentDefinition, task: String, context: String = "", avoidModel: String? = nil, spendLimit: Double? = nil, resumeState: JSONValue? = nil, answer: String? = nil, tools: [any AgentTool] = []) {
        self.definition = definition
        self.task = task
        self.context = context
        self.avoidModel = avoidModel
        self.spendLimit = spendLimit
        self.resumeState = resumeState
        self.answer = answer
        self.tools = tools
    }
}

public struct AgentExecutionQuestion: Sendable, Hashable {
    public var text: String
    public var options: [String]
    public init(text: String, options: [String]) { self.text = text; self.options = options }
}

public enum AgentGoalOutcome: String, Codable, Sendable, Hashable {
    case met, notMet, malformed

    public static func parse(_ output: String) -> AgentGoalOutcome {
        let markers = output.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0 == "GOAL_MET" || $0 == "GOAL_NOT_MET" }
        guard markers.count == 1 else { return .malformed }
        return markers[0] == "GOAL_MET" ? .met : .notMet
    }
}

public struct AgentHelperResult: Sendable, Hashable {
    public var agentID: String
    public var name: String
    public var output: String
    public var model: String?
    public var cost: Double
}

public struct AgentExecutionResult: Sendable, Hashable {
    public var output: String
    public var model: String?
    public var goalOutcome: AgentGoalOutcome
    public var cost: Double
    public var needsSpendingApproval: Bool
    public var pendingQuestion: AgentExecutionQuestion?
    public var helpers: [AgentHelperResult]
    public var resumeState: JSONValue?

    public var goalMet: Bool { goalOutcome == .met }

    public init(output: String, model: String? = nil, goalMet: Bool = false, goalOutcome: AgentGoalOutcome? = nil, cost: Double = 0, needsSpendingApproval: Bool = false, pendingQuestion: AgentExecutionQuestion? = nil, helpers: [AgentHelperResult] = [], resumeState: JSONValue? = nil) {
        self.output = output
        self.model = model
        self.goalOutcome = goalOutcome ?? (goalMet ? .met : .notMet)
        self.cost = cost
        self.needsSpendingApproval = needsSpendingApproval
        self.pendingQuestion = pendingQuestion
        self.helpers = helpers
        self.resumeState = resumeState
    }
}

public enum AgentExecutorError: Error, Sendable, Equatable {
    case unknownAgent(String)
    case tooManyHelpers(maximum: Int)
}

/// Runs bounded helpers independently, joins their results in declaration order, then gives the
/// joined evidence to the lead agent. The injected runner is the same phone/cloud agent loop used
/// for ordinary work; this type owns fan-out policy rather than a second execution stack.
public struct AgentExecutor: Sendable {
    public typealias Runner = @Sendable (AgentInvocation) async throws -> AgentExecutionResult
    private let definitions: [String: AgentDefinition]
    private let runner: Runner

    public init(definitions: [AgentDefinition] = BuiltInAgents.all, runner: @escaping Runner) {
        self.definitions = Dictionary(uniqueKeysWithValues: definitions.map { ($0.id, $0) })
        self.runner = runner
    }

    public func run(_ invocation: AgentInvocation) async throws -> AgentExecutionResult {
        try await runner(invocation)
    }

    public func execute(
        agentID: String,
        task: String,
        context: String = "",
        helpers: [AgentInvocation] = [],
        primaryModel: String? = nil,
        spendLimit: Double? = nil,
        resumeState: JSONValue? = nil,
        answer: String? = nil,
        tools: [any AgentTool] = []
    ) async throws -> AgentExecutionResult {
        guard let lead = definitions[agentID] else { throw AgentExecutorError.unknownAgent(agentID) }
        guard helpers.count <= lead.maximumHelpers else {
            throw AgentExecutorError.tooManyHelpers(maximum: lead.maximumHelpers)
        }

        let helperSpendLimit = spendLimit.map { $0 / Double(helpers.count + 1) }
        var helperResults = Array<AgentExecutionResult?>(repeating: nil, count: helpers.count)
        try await withThrowingTaskGroup(of: (Int, AgentExecutionResult).self) { group in
            for (index, helper) in helpers.enumerated() {
                guard let definition = definitions[helper.definition.id] else { throw AgentExecutorError.unknownAgent(helper.definition.id) }
                group.addTask {
                    var invocation = helper
                    invocation.definition = definition
                    if invocation.definition.modelPolicy == .differentFromPrimary { invocation.avoidModel = primaryModel }
                    invocation.spendLimit = helperSpendLimit
                    return (index, try await runner(invocation))
                }
            }
            for try await (index, result) in group { helperResults[index] = result }
        }

        let joined = helperResults.enumerated().compactMap { index, result -> String? in
            result.map { "Helper \(index + 1) (\(helpers[index].definition.name)):\n\($0.output)" }
        }.joined(separator: "\n\n")
        let fullContext = [context, joined].filter { !$0.isEmpty }.joined(separator: "\n\nIndependent helper reports:\n")
        let helperCost = helperResults.compactMap { $0?.cost }.reduce(0, +)
        let helperEvidence = helperResults.enumerated().compactMap { index, result -> AgentHelperResult? in
            result.map { AgentHelperResult(agentID: helpers[index].definition.id, name: helpers[index].definition.name, output: $0.output, model: $0.model, cost: $0.cost) }
        }
        if let paused = helperResults.compactMap({ $0 }).first(where: { $0.pendingQuestion != nil || $0.needsSpendingApproval }) {
            return AgentExecutionResult(output: joined, model: paused.model, cost: helperCost, needsSpendingApproval: paused.needsSpendingApproval, pendingQuestion: paused.pendingQuestion, helpers: helperEvidence)
        }
        let leadSpendLimit = spendLimit.map { max(0.000_001, $0 - helperCost) }
        var invocation = AgentInvocation(
            definition: lead, task: task, context: fullContext, spendLimit: leadSpendLimit,
            resumeState: resumeState, answer: answer, tools: tools
        )
        if lead.modelPolicy == .differentFromPrimary { invocation.avoidModel = primaryModel }
        var result = try await runner(invocation)
        result.cost += helperCost
        result.helpers = helperEvidence
        return result
    }
}

/// Shared bounded scheduler behind the agent-visible helper tool. It reserves the caller's
/// declared allowance across repeated calls, executes children independently, and retains the
/// exact ordered outputs and model IDs for workflow checkpoints.
public actor AgentHelperCoordinator {
    private let lead: AgentDefinition
    private let definitions: [String: AgentDefinition]
    private let context: String
    private let spendLimit: Double?
    private let runner: AgentExecutor.Runner
    private var launched = 0
    private var records: [AgentHelperResult] = []

    public init(lead: AgentDefinition, definitions: [AgentDefinition], context: String, spendLimit: Double?, runner: @escaping AgentExecutor.Runner) {
        self.lead = lead
        self.definitions = Dictionary(uniqueKeysWithValues: definitions.map { ($0.id, $0) })
        self.context = context
        self.spendLimit = spendLimit
        self.runner = runner
    }

    public func launch(_ requests: [(agentID: String, task: String)]) async throws -> [AgentHelperResult] {
        guard !requests.isEmpty else { throw ToolInputError("Choose at least one helper.") }
        guard launched + requests.count <= lead.maximumHelpers else {
            throw AgentExecutorError.tooManyHelpers(maximum: lead.maximumHelpers)
        }
        let offset = launched
        launched += requests.count
        let priorCost = records.reduce(0) { $0 + $1.cost }
        let operationLimit = spendLimit.map { max(0.000_001, $0 - priorCost) / Double(requests.count) }
        let resolved = try requests.map { request -> (AgentDefinition, String) in
            guard let definition = definitions[request.agentID] else { throw AgentExecutorError.unknownAgent(request.agentID) }
            let task = request.task.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !task.isEmpty else { throw ToolInputError("Every helper needs a task.") }
            return (definition, task)
        }
        var values = Array<AgentExecutionResult?>(repeating: nil, count: resolved.count)
        try await withThrowingTaskGroup(of: (Int, AgentExecutionResult).self) { group in
            for (index, item) in resolved.enumerated() {
                group.addTask {
                    let invocation = AgentInvocation(definition: item.0, task: item.1, context: self.context, spendLimit: operationLimit)
                    return (index, try await self.runner(invocation))
                }
            }
            for try await (index, value) in group { values[index] = value }
        }
        let launchedRecords = resolved.enumerated().map { index, item in
            let value = values[index]!
            return AgentHelperResult(agentID: item.0.id, name: item.0.name, output: value.output, model: value.model, cost: value.cost)
        }
        records += launchedRecords
        return launchedRecords
    }

    public func results() -> [AgentHelperResult] { records }
}

public struct LaunchHelpersTool: AgentTool {
    public let name = "launch_helpers"
    private let lead: AgentDefinition
    private let definitions: [AgentDefinition]
    private let coordinator: AgentHelperCoordinator

    public init(lead: AgentDefinition, definitions: [AgentDefinition], coordinator: AgentHelperCoordinator) {
        self.lead = lead; self.definitions = definitions; self.coordinator = coordinator
    }

    public var spec: ToolSpec {
        ToolSpec(name: name, description: "Launch independent helper agents side by side, wait for all of them, and return their reports in the requested order. At most \(lead.maximumHelpers) helpers may be launched for this agent step.", parameters: [
            "type": "object",
            "properties": [
                "helpers": [
                    "type": "array", "minItems": 1, "maxItems": .number(Double(lead.maximumHelpers)),
                    "items": [
                        "type": "object",
                        "properties": [
                            "agent_id": ["type": "string", "enum": .array(definitions.map { .string($0.id) })],
                            "task": ["type": "string"],
                        ],
                        "required": ["agent_id", "task"], "additionalProperties": false,
                    ],
                ],
            ],
            "required": ["helpers"], "additionalProperties": false,
        ])
    }

    public func runningSummary(for arguments: JSONValue) -> String { "Running helper agents…" }

    public func run(arguments: JSONValue, progress: @escaping @Sendable (String) -> Void) async throws -> ToolOutput {
        guard let values = arguments["helpers"]?.arrayValue else { throw ToolInputError("launch_helpers needs a helpers list.") }
        let requests = try values.map { value -> (String, String) in
            (try value.requiredString("agent_id"), try value.requiredString("task"))
        }
        progress("Running \(requests.count) helper agent\(requests.count == 1 ? "" : "s")…")
        let results = try await coordinator.launch(requests.map { (agentID: $0.0, task: $0.1) })
        let detail = results.enumerated().map { index, result in
            "Helper \(index + 1) (\(result.name), \(result.model ?? "model not reported")):\n\(result.output)"
        }.joined(separator: "\n\n")
        return ToolOutput(forModel: detail, summary: "Finished \(results.count) helper agent\(results.count == 1 ? "" : "s")", detail: detail, billedCost: results.reduce(0) { $0 + $1.cost })
    }
}
