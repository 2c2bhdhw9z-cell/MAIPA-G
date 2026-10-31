import Foundation

public struct AgentInvocation: Sendable {
    public var definition: AgentDefinition
    public var task: String
    public var context: String
    public var avoidModel: String?
    /// Optional explicit model override (used by Kiro workflow steps).
    public var preferredModelID: String?
    /// Optional explicit thinking effort override (used by Kiro workflow steps).
    public var preferredEffort: ThinkingLevel?
    /// Remaining aggregate workflow allowance for this paid agent operation.
    public var spendLimit: Double?
    /// Opaque, checkpointed chat state for resuming one exact paused agent/tool call.
    public var resumeState: JSONValue?
    public var answer: String?
    /// Scheduler capabilities supplied only to this invocation. Helper children receive none.
    public var tools: [any AgentTool]
    /// Live progress callback (`(toolCount, latestSummary)`) so parent sub-agent/workflow cards update live.
    public var onProgress: (@Sendable (Int, String) -> Void)?

    public init(
        definition: AgentDefinition,
        task: String,
        context: String = "",
        avoidModel: String? = nil,
        preferredModelID: String? = nil,
        preferredEffort: ThinkingLevel? = nil,
        spendLimit: Double? = nil,
        resumeState: JSONValue? = nil,
        answer: String? = nil,
        tools: [any AgentTool] = [],
        onProgress: (@Sendable (Int, String) -> Void)? = nil
    ) {
        self.definition = definition
        self.task = task
        self.context = context
        self.avoidModel = avoidModel
        self.preferredModelID = preferredModelID
        self.preferredEffort = preferredEffort
        self.spendLimit = spendLimit
        self.resumeState = resumeState
        self.answer = answer
        self.tools = tools
        self.onProgress = onProgress
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
    public var toolCallCount: Int
    public var toolSummaries: [String]
    public var status: String

    public init(
        agentID: String,
        name: String,
        output: String,
        model: String? = nil,
        cost: Double = 0,
        toolCallCount: Int = 0,
        toolSummaries: [String] = [],
        status: String = "completed"
    ) {
        self.agentID = agentID
        self.name = name
        self.output = output
        self.model = model
        self.cost = cost
        self.toolCallCount = toolCallCount
        self.toolSummaries = toolSummaries
        self.status = status
    }
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
    public var toolCallCount: Int
    public var toolSummaries: [String]
    public var status: String

    public var goalMet: Bool { goalOutcome == .met }

    public init(
        output: String,
        model: String? = nil,
        goalMet: Bool = false,
        goalOutcome: AgentGoalOutcome? = nil,
        cost: Double = 0,
        needsSpendingApproval: Bool = false,
        pendingQuestion: AgentExecutionQuestion? = nil,
        helpers: [AgentHelperResult] = [],
        resumeState: JSONValue? = nil,
        toolCallCount: Int = 0,
        toolSummaries: [String] = [],
        status: String = "completed"
    ) {
        self.output = output
        self.model = model
        self.goalOutcome = goalOutcome ?? (goalMet ? .met : .notMet)
        self.cost = cost
        self.needsSpendingApproval = needsSpendingApproval
        self.pendingQuestion = pendingQuestion
        self.helpers = helpers
        self.resumeState = resumeState
        self.toolCallCount = toolCallCount
        self.toolSummaries = toolSummaries
        self.status = status
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

    public init(definitions: [AgentDefinition] = BuiltInAgents.allIncludingKiroSubagents, runner: @escaping Runner) {
        self.definitions = Dictionary(definitions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
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
        preferredModelID: String? = nil,
        preferredEffort: ThinkingLevel? = nil,
        spendLimit: Double? = nil,
        resumeState: JSONValue? = nil,
        answer: String? = nil,
        tools: [any AgentTool] = [],
        onProgress: (@Sendable (Int, String) -> Void)? = nil
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
            result.map {
                AgentHelperResult(
                    agentID: helpers[index].definition.id,
                    name: helpers[index].definition.name,
                    output: $0.output,
                    model: $0.model,
                    cost: $0.cost,
                    toolCallCount: $0.toolCallCount,
                    toolSummaries: $0.toolSummaries,
                    status: $0.status
                )
            }
        }
        if let paused = helperResults.compactMap({ $0 }).first(where: { $0.pendingQuestion != nil || $0.needsSpendingApproval }) {
            return AgentExecutionResult(output: joined, model: paused.model, cost: helperCost, needsSpendingApproval: paused.needsSpendingApproval, pendingQuestion: paused.pendingQuestion, helpers: helperEvidence)
        }
        let leadSpendLimit = spendLimit.map { max(0.000_001, $0 - helperCost) }
        var invocation = AgentInvocation(
            definition: lead,
            task: task,
            context: fullContext,
            preferredModelID: preferredModelID,
            preferredEffort: preferredEffort,
            spendLimit: leadSpendLimit,
            resumeState: resumeState,
            answer: answer,
            tools: tools,
            onProgress: onProgress
        )
        if lead.modelPolicy == .differentFromPrimary { invocation.avoidModel = primaryModel }
        var result = try await runner(invocation)
        result.cost += helperCost
        result.helpers = helperEvidence
        return result
    }
}

/// Shared bounded scheduler behind the agent-visible sub-agent tool (`launch_helpers`). It reserves
/// the caller's declared allowance across repeated calls, executes children independently in fresh
/// context windows, streams live tool counts, and handles cancellation cleanly (`status == "cancelled"`).
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
        self.definitions = Dictionary(definitions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        self.context = context
        self.spendLimit = spendLimit
        self.runner = runner
    }

    public func launch(
        _ requests: [(agentID: String, task: String)],
        onProgress: (@Sendable (String) -> Void)? = nil
    ) async throws -> [AgentHelperResult] {
        guard !requests.isEmpty else { throw ToolInputError("Choose at least one helper.") }
        guard launched + requests.count <= lead.maximumHelpers else {
            throw AgentExecutorError.tooManyHelpers(maximum: lead.maximumHelpers)
        }
        launched += requests.count
        let priorCost = records.reduce(0) { $0 + $1.cost }
        let operationLimit = spendLimit.map { max(0.000_001, $0 - priorCost) / Double(requests.count) }
        let resolved = try requests.map { request -> (AgentDefinition, String) in
            guard let definition = definitions[request.agentID] else { throw AgentExecutorError.unknownAgent(request.agentID) }
            let task = request.task.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !task.isEmpty else { throw ToolInputError("Every helper needs a task.") }
            return (definition, task)
        }

        let liveCounts = LiveHelperProgressTracker(names: resolved.map { $0.0.name })
        var values = Array<AgentExecutionResult?>(repeating: nil, count: resolved.count)
        do {
            try await withThrowingTaskGroup(of: (Int, AgentExecutionResult).self) { group in
                for (index, item) in resolved.enumerated() {
                    group.addTask {
                        let invocation = AgentInvocation(
                            definition: item.0,
                            task: item.1,
                            context: self.context,
                            spendLimit: operationLimit,
                            onProgress: { toolCount, latest in
                                let line = liveCounts.update(index: index, toolCount: toolCount, latest: latest)
                                onProgress?(line)
                            }
                        )
                        do {
                            return (index, try await self.runner(invocation))
                        } catch is CancellationError {
                            return (
                                index,
                                AgentExecutionResult(
                                    output: "cancelled",
                                    cost: 0,
                                    toolCallCount: liveCounts.count(at: index),
                                    status: "cancelled"
                                )
                            )
                        }
                    }
                }
                for try await (index, value) in group { values[index] = value }
            }
        } catch is CancellationError {
            let cancelledRecords = resolved.enumerated().map { index, item -> AgentHelperResult in
                if let completed = values[index] {
                    return AgentHelperResult(
                        agentID: item.0.id,
                        name: item.0.name,
                        output: completed.output,
                        model: completed.model,
                        cost: completed.cost,
                        toolCallCount: completed.toolCallCount,
                        toolSummaries: completed.toolSummaries,
                        status: completed.status
                    )
                }
                return AgentHelperResult(
                    agentID: item.0.id,
                    name: item.0.name,
                    output: "cancelled",
                    toolCallCount: liveCounts.count(at: index),
                    status: "cancelled"
                )
            }
            records += cancelledRecords
            return cancelledRecords
        }

        let launchedRecords = resolved.enumerated().map { index, item in
            let value = values[index]!
            return AgentHelperResult(
                agentID: item.0.id,
                name: item.0.name,
                output: value.output,
                model: value.model,
                cost: value.cost,
                toolCallCount: value.toolCallCount,
                toolSummaries: value.toolSummaries,
                status: value.status
            )
        }
        records += launchedRecords
        return launchedRecords
    }

    public func results() -> [AgentHelperResult] { records }
}

private final class LiveHelperProgressTracker: @unchecked Sendable {
    private let lock = NSLock()
    private let names: [String]
    private var counts: [Int]
    private var latestSummaries: [String]

    init(names: [String]) {
        self.names = names
        self.counts = Array(repeating: 0, count: names.count)
        self.latestSummaries = Array(repeating: "", count: names.count)
    }

    func count(at index: Int) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return counts.indices.contains(index) ? counts[index] : 0
    }

    func update(index: Int, toolCount: Int, latest: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        if counts.indices.contains(index) {
            counts[index] = toolCount
            latestSummaries[index] = latest
        }
        if names.count == 1 {
            let toolsWord = toolCount == 1 ? "1 tool" : "\(toolCount) tools"
            let suffix = latest.isEmpty ? "" : " · \(latest)"
            return "Sub-agent: \(names[0]) · \(toolsWord)\(suffix)"
        }
        let total = counts.reduce(0, +)
        let roleList = names.joined(separator: ", ")
        return "Sub-agents (\(names.count)): \(roleList) · \(total) tools"
    }
}

/// Allows `Custom Agent Creator` (or the main chat when asked) to save a reusable custom sub-agent.
public struct CreateCustomAgentTool: AgentTool {
    public let name = "create_custom_agent"
    private let saveHandler: @Sendable (AgentDefinition) async throws -> AgentDefinition

    public init(saveHandler: @escaping @Sendable (AgentDefinition) async throws -> AgentDefinition) {
        self.saveHandler = saveHandler
    }

    public var spec: ToolSpec {
        ToolSpec(
            name: name,
            description: "Save a reusable custom sub-agent to MAIPA-G's Agents library so it can be invoked in chat (`launch_helpers`) or Workflows.",
            parameters: [
                "type": "object",
                "properties": [
                    "name": ["type": "string", "description": "Short human-readable role name, such as \"API Auditor\"."],
                    "summary": ["type": "string", "description": "One-sentence description of when to use this sub-agent."],
                    "instructions": ["type": "string", "description": "Focused system instructions for this sub-agent."],
                    "read_only": ["type": "boolean", "description": "True if this sub-agent should inspect and report only without modifying files or running mutating commands. Default true."],
                    "allowed_tools": [
                        "type": "array",
                        "items": ["type": "string"],
                        "description": "Optional explicit list of tool names this sub-agent may call.",
                    ],
                ],
                "required": ["name", "summary", "instructions"],
            ]
        )
    }

    public func runningSummary(for arguments: JSONValue) -> String {
        "Creating custom sub-agent \(arguments.optionalString("name") ?? "")…"
    }

    public func approvalAfterOutsideContent(for arguments: JSONValue) async -> ToolApprovalRequest? {
        let agentName = arguments.optionalString("name") ?? "Custom Agent"
        return ToolApprovalRequest(question: "Save new custom sub-agent \"\(agentName)\" to your Agents library?", allowLabel: "Save agent")
    }

    public func run(arguments: JSONValue, progress: @escaping @Sendable (String) -> Void) async throws -> ToolOutput {
        let title = try arguments.requiredString("name")
        let summary = try arguments.requiredString("summary")
        let instructions = try arguments.requiredString("instructions")
        let readOnly = arguments.optionalBool("read_only") ?? true
        let customTools = arguments["allowed_tools"]?.arrayValue?.compactMap(\.stringValue).filter { !$0.isEmpty }
        let tools = customTools?.isEmpty == false
            ? customTools!
            : (readOnly ? BuiltInAgents.inspectToolNames : BuiltInAgents.generalExecutionToolNames)
        let draft = AgentDefinition(
            id: "custom:\(UUID().uuidString.lowercased())",
            name: String(title.prefix(60)),
            summary: String(summary.prefix(200)),
            instructions: String(instructions.prefix(12_000)),
            allowedTools: tools,
            difficulty: readOnly ? .normal : .hard,
            modelPolicy: .automatic,
            behavior: readOnly ? .reportOnly : .changesAllowed,
            maximumHelpers: 0,
            isBuiltIn: false
        )
        let saved = try await saveHandler(draft)
        return ToolOutput(
            forModel: "Saved custom sub-agent \"\(saved.name)\" (id: \(saved.id), mode: \(readOnly ? "read-only" : "changes allowed")).",
            summary: "Created sub-agent \(saved.name)",
            detail: "\(saved.name) (\(saved.id))\n\(saved.summary)"
        )
    }
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
        let roster = definitions.prefix(30).map { "\($0.id) (\($0.name): \($0.summary))" }.joined(separator: "; ")
        return ToolSpec(
            name: name,
            description: """
            Launch Kiro-style sub-agents in isolated context windows (in parallel when given multiple items), wait for them, and return their structured reports. \
            Prefer `context-gatherer` for parallel codebase/web exploration, `general-task-execution` for focused multi-step implementation/verification, \
            `semantic-reviewer` for deep code/security review, `introspect` for MAIPA-G status, `custom-agent-creator` to create reusable agents, \
            or any custom/repo sub-agent. At most \(lead.maximumHelpers) sub-agents per call. Available sub-agents: \(roster)
            """,
            parameters: [
                "type": "object",
                "properties": [
                    "helpers": [
                        "type": "array", "minItems": 1, "maxItems": .number(Double(lead.maximumHelpers)),
                        "items": [
                            "type": "object",
                            "properties": [
                                "agent_id": ["type": "string", "enum": .array(definitions.map { .string($0.id) })],
                                "task": ["type": "string", "description": "Self-contained task instructions for this sub-agent."],
                            ],
                            "required": ["agent_id", "task"], "additionalProperties": false,
                        ],
                    ],
                ],
                "required": ["helpers"], "additionalProperties": false,
            ]
        )
    }

    public func runningSummary(for arguments: JSONValue) -> String {
        let ids = (arguments["helpers"]?.arrayValue ?? []).compactMap { $0["agent_id"]?.stringValue }
        guard !ids.isEmpty else { return "Sub-agent: running…" }
        let names = ids.map { id in definitions.first(where: { $0.id == id })?.name ?? id }
        if names.count == 1 {
            return "Sub-agent: \(names[0]) · 0 tools"
        }
        return "Sub-agents (\(names.count)): \(names.joined(separator: ", "))…"
    }

    public func run(arguments: JSONValue, progress: @escaping @Sendable (String) -> Void) async throws -> ToolOutput {
        guard let values = arguments["helpers"]?.arrayValue else { throw ToolInputError("launch_helpers needs a helpers list.") }
        let requests = try values.map { value -> (String, String) in
            (try value.requiredString("agent_id"), try value.requiredString("task"))
        }
        let names = requests.map { id, _ in definitions.first(where: { $0.id == id })?.name ?? id }
        progress(names.count == 1 ? "Sub-agent: \(names[0]) · starting…" : "Sub-agents (\(names.count)): \(names.joined(separator: ", "))…")
        let results = try await coordinator.launch(
            requests.map { (agentID: $0.0, task: $0.1) },
            onProgress: { line in progress(line) }
        )
        let totalTools = results.reduce(0) { $0 + $1.toolCallCount }
        let allCancelled = !results.isEmpty && results.allSatisfy { $0.status == "cancelled" }

        let modelReport = results.enumerated().map { index, result in
            if result.status == "cancelled" {
                return "Sub-agent \(index + 1) (\(result.name)): cancelled"
            }
            let toolBadge = result.toolCallCount == 1 ? "1 tool" : "\(result.toolCallCount) tools"
            return "Sub-agent \(index + 1) (\(result.name) · \(toolBadge) · \(result.model ?? "model not reported")):\n\(result.output)"
        }.joined(separator: "\n\n")

        let uiDetail = results.map { result in
            let toolBadge = result.toolCallCount == 1 ? "1 tool" : "\(result.toolCallCount) tools"
            let modelBadge = result.model.map { " · \($0)" } ?? ""
            let stepsLine = result.toolSummaries.isEmpty ? "" : "\nTools used: " + result.toolSummaries.prefix(8).joined(separator: " → ")
            return "### Sub-agent: \(result.name) (\(toolBadge)\(modelBadge))\nStatus: \(result.status)\(stepsLine)\n\n\(result.output)"
        }.joined(separator: "\n\n---\n\n")

        let summaryLine: String
        if allCancelled {
            summaryLine = names.count == 1 ? "Sub-agent: \(names[0]) · cancelled" : "Sub-agents · cancelled"
        } else if names.count == 1 {
            let tWord = totalTools == 1 ? "1 tool" : "\(totalTools) tools"
            summaryLine = "Sub-agent: \(names[0]) · \(tWord)"
        } else {
            let tWord = totalTools == 1 ? "1 tool" : "\(totalTools) tools"
            summaryLine = "Sub-agents: \(names.joined(separator: ", ")) · \(tWord)"
        }

        return ToolOutput(
            forModel: allCancelled ? "cancelled" : modelReport,
            summary: summaryLine,
            detail: uiDetail,
            billedCost: results.reduce(0) { $0 + $1.cost }
        )
    }
}
