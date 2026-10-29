import Foundation

public enum WorkflowNodeStatus: String, Codable, Sendable, Hashable { case pending, running, waiting, completed, failed, cancelled }

public struct WorkflowQuestion: Codable, Sendable, Hashable {
    public var nodeID: String
    public var text: String
    public var options: [String]
    public init(nodeID: String, text: String, options: [String]) {
        self.nodeID = nodeID; self.text = text; self.options = options
    }
}

public struct WorkflowOutput: Codable, Sendable, Hashable {
    public var nodeID: String
    public var title: String
    public var text: String
    public var model: String?
    public init(nodeID: String, title: String, text: String, model: String? = nil) {
        self.nodeID = nodeID; self.title = title; self.text = text; self.model = model
    }
}

public struct WorkflowCheckpoint: Codable, Sendable, Hashable {
    public static let currentFormat = 1
    public var format = currentFormat
    public var workflowID: String
    public var request: String
    public var statuses: [String: WorkflowNodeStatus]
    public var repeatIterations: [String: Int]
    public var answers: [String: String]
    public var outputs: [WorkflowOutput]
    public var pendingQuestion: WorkflowQuestion?
    public var cumulativeCost: Double
    public var isCancelled: Bool
    public var updatedAt: Date

    public init(workflowID: String, request: String) {
        self.workflowID = workflowID; self.request = request; statuses = [:]
        repeatIterations = [:]; answers = [:]; outputs = []; cumulativeCost = 0
        isCancelled = false; updatedAt = Date()
    }
}

public enum WorkflowRunOutcome: Sendable, Hashable {
    case completed(WorkflowCheckpoint)
    case waiting(WorkflowCheckpoint, WorkflowQuestion)
    case cancelled(WorkflowCheckpoint)
    case failed(WorkflowCheckpoint, String)
}

public enum WorkflowEngineError: Error, Sendable, Equatable {
    case notApproved
    case invalid([String])
    case unknownAgent(String)
}

/// A restartable workflow interpreter. Every transition is checkpointed. Agent steps share the
/// common executor; parallel children run concurrently and their outputs are joined in declared
/// order. Repeat nodes always stop for the user after their finite maximum.
public actor WorkflowEngine {
    public typealias Checkpointer = @Sendable (WorkflowCheckpoint) async throws -> Void

    private let definition: WorkflowDefinition
    private let agents: [String: AgentDefinition]
    private let executor: AgentExecutor
    private let checkpointer: Checkpointer
    public private(set) var state: WorkflowCheckpoint

    public init(
        definition: WorkflowDefinition,
        checkpoint: WorkflowCheckpoint? = nil,
        agents: [AgentDefinition] = BuiltInAgents.all,
        runner: @escaping AgentExecutor.Runner,
        checkpointer: @escaping Checkpointer = { _ in }
    ) {
        self.definition = definition
        self.agents = Dictionary(uniqueKeysWithValues: agents.map { ($0.id, $0) })
        executor = AgentExecutor(definitions: agents, runner: runner)
        self.checkpointer = checkpointer
        state = checkpoint ?? WorkflowCheckpoint(workflowID: definition.id, request: "")
    }

    public func run(request: String? = nil) async -> WorkflowRunOutcome {
        if let request, state.request.isEmpty { state.request = request }
        guard definition.isApproved else { return .failed(state, String(describing: WorkflowEngineError.notApproved)) }
        let errors = definition.validationErrors(agentIDs: Set(agents.keys))
        guard errors.isEmpty else { return .failed(state, errors.joined(separator: " ")) }
        if state.isCancelled { return .cancelled(state) }
        do {
            try await save()
            for node in definition.steps {
                _ = try await run(node)
            }
            state.pendingQuestion = nil
            try await save()
            return .completed(state)
        } catch let pause as Pause {
            return .waiting(state, pause.question)
        } catch is CancellationError {
            state.isCancelled = true
            markRunning(.cancelled)
            try? await save()
            return .cancelled(state)
        } catch {
            markRunning(.failed)
            try? await save()
            return .failed(state, String(describing: error))
        }
    }

    public func answer(nodeID: String, answer: String) async throws {
        state.answers[nodeID] = answer
        state.pendingQuestion = nil
        if state.statuses[nodeID] == .waiting { state.statuses[nodeID] = .pending }
        try await save()
    }

    public func cancel() async {
        state.isCancelled = true
        markRunning(.cancelled)
        try? await save()
    }

    private func run(_ node: WorkflowNode, goalCondition: String? = nil) async throws -> Bool {
        try Task.checkCancellation()
        if state.isCancelled { throw CancellationError() }
        if state.statuses[node.id] == .completed { return false }
        switch node.kind {
        case .agent: return try await runAgent(node, goalCondition: goalCondition)
        case .sequence:
            state.statuses[node.id] = .running; try await save()
            var goalMet = false
            for (index, child) in node.children.enumerated() {
                let childGoal = index == node.children.count - 1 ? goalCondition : nil
                goalMet = try await run(child, goalCondition: childGoal) || goalMet
            }
            state.statuses[node.id] = .completed; try await save()
            return goalMet
        case .parallel: return try await runParallel(node, goalCondition: goalCondition)
        case .stopAndAsk: return try await runAsk(node)
        case .repeatUntil: return try await runRepeat(node)
        }
    }

    private func runAgent(_ node: WorkflowNode, goalCondition: String? = nil) async throws -> Bool {
        guard let agentID = node.agentID, agents[agentID] != nil else { throw WorkflowEngineError.unknownAgent(node.agentID ?? "") }
        state.statuses[node.id] = .running; try await save()
        var task = node.instruction ?? node.title
        if let goalCondition, !goalCondition.isEmpty {
            task += "\n\nRepeat goal: \(goalCondition)\nEnd with a line containing exactly GOAL_MET only when current evidence proves this goal is met. Otherwise end with GOAL_NOT_MET."
        }
        let result = try await executor.execute(agentID: agentID, task: task, context: context)
        if state.isCancelled { throw CancellationError() }
        state.outputs.append(WorkflowOutput(nodeID: node.id, title: node.title, text: result.output, model: result.model))
        state.cumulativeCost += result.cost
        state.statuses[node.id] = .completed; try await save()
        return result.goalMet
    }

    private func runParallel(_ node: WorkflowNode, goalCondition: String? = nil) async throws -> Bool {
        state.statuses[node.id] = .running
        for child in node.children { state.statuses[child.id] = .running }
        try await save()
        let baseContext = context
        let resolved = try node.children.map { child -> (WorkflowNode, AgentDefinition) in
            guard child.kind == .agent, let id = child.agentID, let agent = agents[id] else { throw WorkflowEngineError.unknownAgent(child.agentID ?? "") }
            return (child, agent)
        }
        let runner = executor
        var results = Array<AgentExecutionResult?>(repeating: nil, count: resolved.count)
        try await withThrowingTaskGroup(of: (Int, AgentExecutionResult).self) { group in
            for (index, item) in resolved.enumerated() {
                group.addTask {
                    var task = item.0.instruction ?? item.0.title
                    if let goalCondition, !goalCondition.isEmpty {
                        task += "\n\nRepeat goal: \(goalCondition)\nEnd with a line containing exactly GOAL_MET only when current evidence proves this goal is met. Otherwise end with GOAL_NOT_MET."
                    }
                    return (index, try await runner.execute(agentID: item.1.id, task: task, context: baseContext))
                }
            }
            for try await (index, result) in group { results[index] = result }
        }
        var goalMet = false
        if state.isCancelled { throw CancellationError() }
        for (index, item) in resolved.enumerated() {
            let result = results[index]!
            state.outputs.append(WorkflowOutput(nodeID: item.0.id, title: item.0.title, text: result.output, model: result.model))
            state.cumulativeCost += result.cost
            state.statuses[item.0.id] = .completed
            goalMet = goalMet || result.goalMet
        }
        state.statuses[node.id] = .completed; try await save()
        return goalMet
    }

    private func runAsk(_ node: WorkflowNode) async throws -> Bool {
        if let answer = state.answers[node.id] {
            if answer.lowercased().contains("stop") {
                state.statuses[node.id] = .cancelled
                state.isCancelled = true
                try await save()
                throw CancellationError()
            }
            state.outputs.append(WorkflowOutput(nodeID: node.id, title: node.title, text: "User answer: \(answer)"))
            state.statuses[node.id] = .completed; try await save()
            return false
        }
        let question = WorkflowQuestion(nodeID: node.id, text: node.question ?? node.title, options: node.options)
        state.statuses[node.id] = .waiting; state.pendingQuestion = question; try await save()
        throw Pause(question: question)
    }

    private func runRepeat(_ node: WorkflowNode) async throws -> Bool {
        state.statuses[node.id] = .running; try await save()
        let maximum = node.maximumIterations ?? 1
        while true {
            let count = state.repeatIterations[node.id, default: 0]
            if count >= maximum {
                if let answer = state.answers[node.id] {
                    state.answers[node.id] = nil
                    if answer.lowercased().contains("stop") {
                        state.statuses[node.id] = .completed; try await save(); return false
                    }
                    state.repeatIterations[node.id] = 0
                } else {
                    let question = WorkflowQuestion(nodeID: node.id, text: "\(node.title) reached its \(maximum)-round limit without meeting the goal. Continue?", options: ["Continue", "Stop"])
                    state.statuses[node.id] = .waiting; state.pendingQuestion = question; try await save()
                    throw Pause(question: question)
                }
            }
            reset(node.children)
            var goalMet = false
            for (index, child) in node.children.enumerated() {
                let condition = index == node.children.count - 1 ? node.successCondition : nil
                goalMet = try await run(child, goalCondition: condition) || goalMet
            }
            state.repeatIterations[node.id, default: 0] += 1
            try await save()
            if goalMet {
                state.statuses[node.id] = .completed; try await save(); return true
            }
        }
    }

    private var context: String {
        let prior = state.outputs.map { "\($0.title):\n\($0.text)" }.joined(separator: "\n\n")
        return ["Original request:\n\(state.request)", prior].filter { !$0.isEmpty }.joined(separator: "\n\nPrevious workflow results:\n")
    }

    private func reset(_ nodes: [WorkflowNode]) {
        for node in nodes {
            state.statuses[node.id] = .pending
            reset(node.children)
        }
    }

    private func markRunning(_ status: WorkflowNodeStatus) {
        for (id, value) in state.statuses where value == .running { state.statuses[id] = status }
    }

    private func save() async throws {
        state.updatedAt = Date()
        try await checkpointer(state)
    }

    private struct Pause: Error { var question: WorkflowQuestion }
}
