import Foundation

public struct AgentLiveProgress: Sendable, Hashable {
    public var model: String?
    public var toolCallCount: Int
    public var latestActivity: String?
    public var toolSummaries: [String]
    public var liveThought: String?
    public var partialOutput: String

    public init(
        model: String? = nil,
        toolCallCount: Int = 0,
        latestActivity: String? = nil,
        toolSummaries: [String] = [],
        liveThought: String? = nil,
        partialOutput: String = ""
    ) {
        self.model = model
        self.toolCallCount = toolCallCount
        self.latestActivity = latestActivity
        self.toolSummaries = toolSummaries
        self.liveThought = liveThought
        self.partialOutput = partialOutput
    }
}

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
    /// Rich live progress callback carrying model, tool list, live thoughts, and partial text for sub-agent cards.
    public var onLiveProgress: (@Sendable (AgentLiveProgress) -> Void)?

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
        onProgress: (@Sendable (Int, String) -> Void)? = nil,
        onLiveProgress: (@Sendable (AgentLiveProgress) -> Void)? = nil
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
        self.onLiveProgress = onLiveProgress
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
    public var task: String
    public var output: String
    public var model: String?
    public var cost: Double
    public var toolCallCount: Int
    public var toolSummaries: [String]
    public var status: String

    public init(
        agentID: String,
        name: String,
        task: String = "",
        output: String,
        model: String? = nil,
        cost: Double = 0,
        toolCallCount: Int = 0,
        toolSummaries: [String] = [],
        status: String = "completed"
    ) {
        self.agentID = agentID
        self.name = name
        self.task = task
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
        let resolvedHelpers = try helpers.map { helper -> (AgentInvocation, AgentDefinition) in
            guard let definition = definitions[helper.definition.id] else {
                throw AgentExecutorError.unknownAgent(helper.definition.id)
            }
            return (helper, definition)
        }
        let helperResultsByIndex: [Int: AgentExecutionResult] = try await withThrowingTaskGroup(of: (Int, AgentExecutionResult).self) { group in
            for (index, pair) in resolvedHelpers.enumerated() {
                group.addTask {
                    var invocation = pair.0
                    invocation.definition = pair.1
                    if invocation.definition.modelPolicy == .differentFromPrimary { invocation.avoidModel = primaryModel }
                    invocation.spendLimit = helperSpendLimit
                    return (index, try await runner(invocation))
                }
            }
            var collected: [Int: AgentExecutionResult] = [:]
            collected.reserveCapacity(resolvedHelpers.count)
            for try await (index, result) in group {
                collected[index] = result
            }
            return collected
        }
        let helperResults: [AgentExecutionResult?] = helpers.indices.map { helperResultsByIndex[$0] }

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
                    task: helpers[index].task,
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
        callID: String = "subagent",
        existingSubagents: [SubagentRunItem]? = nil,
        onProgress: (@Sendable (String) -> Void)? = nil,
        onLiveUpdate: (@Sendable (ToolLiveUpdate) -> Void)? = nil
    ) async throws -> [AgentHelperResult] {
        guard !requests.isEmpty else { throw ToolInputError("Choose at least one helper.") }
        guard launched + requests.count <= lead.maximumHelpers else {
            throw AgentExecutorError.tooManyHelpers(maximum: lead.maximumHelpers)
        }
        let batchOffset = launched
        launched += requests.count
        let priorCost = records.reduce(0) { $0 + $1.cost }
        let resolved = try requests.map { request -> (AgentDefinition, String) in
            guard let definition = definitions[request.agentID] else { throw AgentExecutorError.unknownAgent(request.agentID) }
            let task = request.task.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !task.isEmpty else { throw ToolInputError("Every helper needs a task.") }
            return (definition, task)
        }

        let completedExisting: [Int: SubagentRunItem] = {
            guard let existingSubagents else { return [:] }
            var map: [Int: SubagentRunItem] = [:]
            for (idx, item) in existingSubagents.enumerated() where idx < resolved.count && item.status == .completed && !item.output.isEmpty {
                map[idx] = item
            }
            return map
        }()
        let remainingCount = max(1, resolved.count - completedExisting.count)
        let resumedPriorCost = completedExisting.values.reduce(0) { $0 + $1.cost }
        let operationLimit = spendLimit.map { max(0.000_001, $0 - priorCost - resumedPriorCost) / Double(remainingCount) }

        let liveTracker = LiveHelperProgressTracker(
            batchOffset: batchOffset,
            callID: callID,
            resolved: resolved,
            completedExisting: completedExisting
        )
        let initialSnapshot = liveTracker.currentUpdate()
        onProgress?(initialSnapshot.summary)
        onLiveUpdate?(initialSnapshot)

        let collected: [Int: AgentExecutionResult] = await withTaskGroup(of: (Int, AgentExecutionResult).self) { group in
            for (index, item) in resolved.enumerated() {
                if let done = completedExisting[index] {
                    group.addTask {
                        let cached = AgentExecutionResult(
                            output: done.output,
                            model: done.model,
                            cost: done.cost,
                            toolCallCount: done.toolCallCount,
                            toolSummaries: done.toolSummaries,
                            status: "completed"
                        )
                        return (index, cached)
                    }
                    continue
                }
                group.addTask {
                    let invocation = AgentInvocation(
                        definition: item.0,
                        task: item.1,
                        context: self.context,
                        spendLimit: operationLimit,
                        onProgress: { toolCount, latest in
                            let live = liveTracker.updateBasic(index: index, toolCount: toolCount, latest: latest)
                            onProgress?(live.summary)
                            onLiveUpdate?(live)
                        },
                        onLiveProgress: { progress in
                            let live = liveTracker.updateRich(index: index, progress: progress)
                            onProgress?(live.summary)
                            onLiveUpdate?(live)
                        }
                    )
                    do {
                        let outcome = try await self.runner(invocation)
                        let live = liveTracker.finish(index: index, result: outcome)
                        onProgress?(live.summary)
                        onLiveUpdate?(live)
                        return (index, outcome)
                    } catch is CancellationError {
                        let cancelled = liveTracker.cancelledResult(at: index)
                        let live = liveTracker.finish(index: index, result: cancelled)
                        onProgress?(live.summary)
                        onLiveUpdate?(live)
                        return (index, cancelled)
                    } catch {
                        if Task.isCancelled {
                            let cancelled = liveTracker.cancelledResult(at: index)
                            let live = liveTracker.finish(index: index, result: cancelled)
                            onProgress?(live.summary)
                            onLiveUpdate?(live)
                            return (index, cancelled)
                        }
                        let failed = liveTracker.failedResult(at: index, error: error)
                        let live = liveTracker.finish(index: index, result: failed)
                        onProgress?(live.summary)
                        onLiveUpdate?(live)
                        return (index, failed)
                    }
                }
            }
            var map: [Int: AgentExecutionResult] = [:]
            map.reserveCapacity(resolved.count)
            for await (index, value) in group {
                map[index] = value
            }
            return map
        }

        let launchedRecords = resolved.enumerated().map { index, item -> AgentHelperResult in
            let value = collected[index] ?? liveTracker.cancelledResult(at: index)
            return AgentHelperResult(
                agentID: item.0.id,
                name: item.0.name,
                task: item.1,
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
    private var items: [SubagentRunItem]

    init(
        batchOffset: Int,
        callID: String,
        resolved: [(AgentDefinition, String)],
        completedExisting: [Int: SubagentRunItem] = [:]
    ) {
        self.items = resolved.enumerated().map { index, pair in
            let stableID = "\(callID)-sub-\(batchOffset + index + 1)"
            if var done = completedExisting[index] {
                done.id = stableID
                return done
            }
            return SubagentRunItem(
                id: stableID,
                agentID: pair.0.id,
                name: pair.0.name,
                task: pair.1,
                status: .running,
                latestActivity: "Starting…"
            )
        }
    }

    func currentUpdate() -> ToolLiveUpdate {
        lock.lock()
        defer { lock.unlock() }
        return buildUpdateLocked()
    }

    func updateBasic(index: Int, toolCount: Int, latest: String) -> ToolLiveUpdate {
        lock.lock()
        defer { lock.unlock() }
        if items.indices.contains(index), items[index].status == .running {
            items[index].toolCallCount = max(items[index].toolCallCount, toolCount)
            if !latest.isEmpty {
                items[index].latestActivity = latest
                if items[index].toolSummaries.last != latest {
                    items[index].toolSummaries.append(latest)
                }
            }
        }
        return buildUpdateLocked()
    }

    func updateRich(index: Int, progress: AgentLiveProgress) -> ToolLiveUpdate {
        lock.lock()
        defer { lock.unlock() }
        if items.indices.contains(index), items[index].status == .running {
            if let model = progress.model, !model.isEmpty {
                items[index].model = model
            }
            items[index].toolCallCount = progress.toolCallCount
            if let latest = progress.latestActivity, !latest.isEmpty {
                items[index].latestActivity = latest
            }
            items[index].toolSummaries = progress.toolSummaries
            items[index].liveThought = progress.liveThought
            if !progress.partialOutput.isEmpty {
                items[index].output = progress.partialOutput
            }
        }
        return buildUpdateLocked()
    }

    func finish(index: Int, result: AgentExecutionResult) -> ToolLiveUpdate {
        lock.lock()
        defer { lock.unlock() }
        if items.indices.contains(index) {
            if let model = result.model, !model.isEmpty {
                items[index].model = model
            }
            items[index].toolCallCount = max(items[index].toolCallCount, result.toolCallCount)
            if !result.toolSummaries.isEmpty {
                items[index].toolSummaries = result.toolSummaries
            }
            items[index].cost = result.cost
            items[index].liveThought = nil
            switch result.status {
            case "cancelled":
                items[index].status = .cancelled
                items[index].latestActivity = "Stopped"
                if items[index].output.isEmpty, result.output != "cancelled" {
                    items[index].output = result.output
                }
            case "failed":
                items[index].status = .failed
                items[index].latestActivity = "Failed"
                items[index].output = result.output
            default:
                items[index].status = .completed
                items[index].latestActivity = "Completed"
                items[index].output = result.output
            }
        }
        return buildUpdateLocked()
    }

    func cancelledResult(at index: Int) -> AgentExecutionResult {
        lock.lock()
        defer { lock.unlock() }
        guard items.indices.contains(index) else {
            return AgentExecutionResult(output: "cancelled", cost: 0, toolCallCount: 0, status: "cancelled")
        }
        let current = items[index]
        return AgentExecutionResult(
            output: current.output.isEmpty ? "cancelled" : current.output,
            model: current.model,
            cost: current.cost,
            toolCallCount: current.toolCallCount,
            toolSummaries: current.toolSummaries,
            status: "cancelled"
        )
    }

    func failedResult(at index: Int, error: Error) -> AgentExecutionResult {
        lock.lock()
        defer { lock.unlock() }
        let message = ErrorExplainer.explain(error).message
        guard items.indices.contains(index) else {
            return AgentExecutionResult(output: message, cost: 0, toolCallCount: 0, status: "failed")
        }
        let current = items[index]
        return AgentExecutionResult(
            output: message,
            model: current.model,
            cost: current.cost,
            toolCallCount: current.toolCallCount,
            toolSummaries: current.toolSummaries,
            status: "failed"
        )
    }

    private func buildUpdateLocked() -> ToolLiveUpdate {
        let total = items.reduce(0) { $0 + $1.toolCallCount }
        let summary: String
        if items.count == 1 {
            let one = items[0]
            let toolsWord = one.toolCallCount == 1 ? "1 action" : "\(one.toolCallCount) actions"
            let suffix = (one.latestActivity?.isEmpty == false) ? " · \(one.latestActivity ?? "")" : ""
            summary = "Sub-agent: \(one.name) · \(toolsWord)\(suffix)"
        } else {
            let runningCount = items.filter { $0.status == .running }.count
            let names = items.map(\.name).joined(separator: ", ")
            let toolsWord = total == 1 ? "1 action" : "\(total) actions"
            let stateWord = runningCount > 0 ? "\(runningCount)/\(items.count) running" : "done"
            summary = "Sub-agents (\(items.count)): \(names) · \(stateWord) · \(toolsWord)"
        }
        let detail = items.map { item in
            let toolsWord = item.toolCallCount == 1 ? "1 action" : "\(item.toolCallCount) actions"
            let modelBadge = item.model.map { " · \($0)" } ?? ""
            let steps = item.toolSummaries.isEmpty ? "" : "\nActions:\n" + item.toolSummaries.map { "- \($0)" }.joined(separator: "\n")
            let body = item.output.isEmpty ? (item.liveThought ?? item.latestActivity ?? "Working…") : item.output
            return "### Sub-agent: \(item.name) (\(toolsWord)\(modelBadge))\nTask: \(item.task)\nStatus: \(item.status.rawValue)\(steps)\n\n\(body)"
        }.joined(separator: "\n\n---\n\n")
        return ToolLiveUpdate(summary: summary, detail: detail, subagents: items)
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
        let tools: [String]
        if let customTools, !customTools.isEmpty {
            tools = customTools
        } else {
            tools = readOnly ? BuiltInAgents.inspectToolNames : BuiltInAgents.generalExecutionToolNames
        }
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
            Prefer `context-gatherer` for parallel or exhaustive codebase/web exploration, `general-task-execution` for focused multi-step implementation/verification, \
            `semantic-reviewer` for deep code/security review, `introspect` for MAIPA-G status, `custom-agent-creator` to create reusable agents, \
            or any custom/repo sub-agent. Preserve the user's exact depth requirements in each sub-agent's `task` — never water down an exhaustive or line-by-line request into a skim. At most \(lead.maximumHelpers) sub-agents per call. Available sub-agents: \(roster)
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
                                "task": ["type": "string", "description": "Complete, self-contained task instructions for this sub-agent, preserving the user's requested thoroughness."],
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
            return "Sub-agent: \(names[0]) · starting…"
        }
        return "Sub-agents (\(names.count)): \(names.joined(separator: ", ")) · starting…"
    }

    public func initialSubagents(for arguments: JSONValue, callID: String) -> [SubagentRunItem]? {
        guard let values = arguments["helpers"]?.arrayValue, !values.isEmpty else { return nil }
        return values.enumerated().compactMap { index, entry in
            guard let id = entry["agent_id"]?.stringValue, !id.isEmpty else { return nil }
            let name = definitions.first(where: { $0.id == id })?.name ?? BuiltInAgents.named(id)?.name ?? id
            let task = entry["task"]?.stringValue ?? ""
            return SubagentRunItem(
                id: "\(callID)-sub-\(index + 1)",
                agentID: id,
                name: name,
                task: task,
                status: .running,
                latestActivity: "Starting…"
            )
        }
    }

    public func run(arguments: JSONValue, progress: @escaping @Sendable (String) -> Void) async throws -> ToolOutput {
        try await runLive(arguments: arguments) { live in
            progress(live.summary)
        }
    }

    public func runLive(arguments: JSONValue, update: @escaping @Sendable (ToolLiveUpdate) -> Void) async throws -> ToolOutput {
        try await runLive(arguments: arguments, callID: "subagent", existingSubagents: nil, update: update)
    }

    public func runLive(
        arguments: JSONValue,
        callID: String,
        existingSubagents: [SubagentRunItem]?,
        update: @escaping @Sendable (ToolLiveUpdate) -> Void
    ) async throws -> ToolOutput {
        guard let values = arguments["helpers"]?.arrayValue else { throw ToolInputError("launch_helpers needs a helpers list.") }
        let requests = try values.map { value -> (String, String) in
            (try value.requiredString("agent_id"), try value.requiredString("task"))
        }
        let names = requests.map { id, _ in definitions.first(where: { $0.id == id })?.name ?? id }
        let results = try await coordinator.launch(
            requests.map { (agentID: $0.0, task: $0.1) },
            callID: callID,
            existingSubagents: existingSubagents,
            onLiveUpdate: { live in update(live) }
        )
        let totalTools = results.reduce(0) { $0 + $1.toolCallCount }
        let allCancelled = !results.isEmpty && results.allSatisfy { $0.status == "cancelled" }
        let allFailed = !results.isEmpty && results.allSatisfy { $0.status == "failed" }

        let modelReport = results.enumerated().map { index, result in
            if result.status == "cancelled" {
                return "Sub-agent \(index + 1) (\(result.name)): cancelled"
            }
            let toolBadge = result.toolCallCount == 1 ? "1 action" : "\(result.toolCallCount) actions"
            let statusTag = result.status == "failed" ? " · failed" : ""
            return "Sub-agent \(index + 1) (\(result.name) · \(toolBadge) · \(result.model ?? "model not reported")\(statusTag)):\n\(result.output)"
        }.joined(separator: "\n\n")

        let uiDetail = results.map { result in
            let toolBadge = result.toolCallCount == 1 ? "1 action" : "\(result.toolCallCount) actions"
            let modelBadge = result.model.map { " · \($0)" } ?? ""
            let stepsLine = result.toolSummaries.isEmpty ? "" : "\nActions:\n" + result.toolSummaries.map { "- \($0)" }.joined(separator: "\n")
            return "### Sub-agent: \(result.name) (\(toolBadge)\(modelBadge))\nTask: \(result.task)\nStatus: \(result.status)\(stepsLine)\n\n\(result.output)"
        }.joined(separator: "\n\n---\n\n")

        let finalSubagents: [SubagentRunItem] = results.enumerated().map { index, result in
            let itemStatus: SubagentRunItem.Status = {
                switch result.status {
                case "cancelled": return .cancelled
                case "failed": return .failed
                default: return .completed
                }
            }()
            return SubagentRunItem(
                id: "\(callID)-sub-\(index + 1)",
                agentID: result.agentID,
                name: result.name,
                task: result.task,
                model: result.model,
                status: itemStatus,
                toolCallCount: result.toolCallCount,
                latestActivity: itemStatus == .completed ? "Completed" : (itemStatus == .cancelled ? "Stopped" : "Failed"),
                toolSummaries: result.toolSummaries,
                output: result.output,
                cost: result.cost
            )
        }

        let summaryLine: String
        if allCancelled {
            summaryLine = names.count == 1 ? "Sub-agent: \(names[0]) · stopped" : "Sub-agents · stopped"
        } else if names.count == 1 {
            let tWord = totalTools == 1 ? "1 action" : "\(totalTools) actions"
            summaryLine = "Sub-agent: \(names[0]) · \(tWord)"
        } else {
            let tWord = totalTools == 1 ? "1 action" : "\(totalTools) actions"
            summaryLine = "Sub-agents (\(names.count)): \(names.joined(separator: ", ")) · \(tWord)"
        }

        return ToolOutput(
            forModel: allCancelled ? "cancelled" : modelReport,
            summary: summaryLine,
            detail: uiDetail,
            isError: allFailed,
            billedCost: results.reduce(0) { $0 + $1.cost },
            subagents: finalSubagents
        )
    }
}
