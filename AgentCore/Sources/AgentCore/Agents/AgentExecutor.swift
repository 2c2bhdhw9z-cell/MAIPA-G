import Foundation

public struct AgentInvocation: Sendable {
    public var definition: AgentDefinition
    public var task: String
    public var context: String
    public var avoidModel: String?

    public init(definition: AgentDefinition, task: String, context: String = "", avoidModel: String? = nil) {
        self.definition = definition
        self.task = task
        self.context = context
        self.avoidModel = avoidModel
    }
}

public struct AgentExecutionResult: Sendable, Hashable {
    public var output: String
    public var model: String?
    public var goalMet: Bool
    public var cost: Double

    public init(output: String, model: String? = nil, goalMet: Bool = false, cost: Double = 0) {
        self.output = output
        self.model = model
        self.goalMet = goalMet
        self.cost = cost
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
        primaryModel: String? = nil
    ) async throws -> AgentExecutionResult {
        guard let lead = definitions[agentID] else { throw AgentExecutorError.unknownAgent(agentID) }
        guard helpers.count <= lead.maximumHelpers else {
            throw AgentExecutorError.tooManyHelpers(maximum: lead.maximumHelpers)
        }

        var helperResults = Array<AgentExecutionResult?>(repeating: nil, count: helpers.count)
        try await withThrowingTaskGroup(of: (Int, AgentExecutionResult).self) { group in
            for (index, helper) in helpers.enumerated() {
                guard let definition = definitions[helper.definition.id] else { throw AgentExecutorError.unknownAgent(helper.definition.id) }
                group.addTask {
                    var invocation = helper
                    invocation.definition = definition
                    if invocation.definition.modelPolicy == .differentFromPrimary { invocation.avoidModel = primaryModel }
                    return (index, try await runner(invocation))
                }
            }
            for try await (index, result) in group { helperResults[index] = result }
        }

        let joined = helperResults.enumerated().compactMap { index, result -> String? in
            result.map { "Helper \(index + 1) (\(helpers[index].definition.name)):\n\($0.output)" }
        }.joined(separator: "\n\n")
        let fullContext = [context, joined].filter { !$0.isEmpty }.joined(separator: "\n\nIndependent helper reports:\n")
        var invocation = AgentInvocation(definition: lead, task: task, context: fullContext)
        if lead.modelPolicy == .differentFromPrimary { invocation.avoidModel = primaryModel }
        var result = try await runner(invocation)
        result.cost += helperResults.compactMap { $0?.cost }.reduce(0, +)
        return result
    }
}
