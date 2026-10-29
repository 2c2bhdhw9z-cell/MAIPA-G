import Foundation

public struct AgentInvocation: Sendable {
    public var definition: AgentDefinition
    public var task: String
    public var context: String
    public var avoidModel: String?
    /// Remaining aggregate workflow allowance for this paid agent operation.
    public var spendLimit: Double?

    public init(definition: AgentDefinition, task: String, context: String = "", avoidModel: String? = nil, spendLimit: Double? = nil) {
        self.definition = definition
        self.task = task
        self.context = context
        self.avoidModel = avoidModel
        self.spendLimit = spendLimit
    }
}

public struct AgentExecutionQuestion: Sendable, Hashable {
    public var text: String
    public var options: [String]
    public init(text: String, options: [String]) { self.text = text; self.options = options }
}

public struct AgentExecutionResult: Sendable, Hashable {
    public var output: String
    public var model: String?
    public var goalMet: Bool
    public var cost: Double
    public var needsSpendingApproval: Bool
    public var pendingQuestion: AgentExecutionQuestion?

    public init(output: String, model: String? = nil, goalMet: Bool = false, cost: Double = 0, needsSpendingApproval: Bool = false, pendingQuestion: AgentExecutionQuestion? = nil) {
        self.output = output
        self.model = model
        self.goalMet = goalMet
        self.cost = cost
        self.needsSpendingApproval = needsSpendingApproval
        self.pendingQuestion = pendingQuestion
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

    public func execute(
        agentID: String,
        task: String,
        context: String = "",
        helpers: [AgentInvocation] = [],
        primaryModel: String? = nil,
        spendLimit: Double? = nil
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
        if let paused = helperResults.compactMap({ $0 }).first(where: { $0.pendingQuestion != nil || $0.needsSpendingApproval }) {
            return AgentExecutionResult(output: joined, model: paused.model, cost: helperCost, needsSpendingApproval: paused.needsSpendingApproval, pendingQuestion: paused.pendingQuestion)
        }
        let leadSpendLimit = spendLimit.map { max(0.000_001, $0 - helperCost) }
        var invocation = AgentInvocation(definition: lead, task: task, context: fullContext, spendLimit: leadSpendLimit)
        if lead.modelPolicy == .differentFromPrimary { invocation.avoidModel = primaryModel }
        var result = try await runner(invocation)
        result.cost += helperCost
        return result
    }
}
