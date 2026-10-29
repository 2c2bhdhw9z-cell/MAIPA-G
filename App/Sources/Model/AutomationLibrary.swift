import AgentCore
import Foundation
import Observation

@MainActor
@Observable
final class AutomationLibrary {
    private(set) var customAgents: [CustomAgentRecord] = []
    private(set) var customWorkflows: [WorkflowRecord] = []
    private(set) var isLoaded = false
    private(set) var lastError: String?

    @ObservationIgnored weak var app: AppModel?
    @ObservationIgnored private let agentStore: ProductStore<CustomAgentRecord>
    @ObservationIgnored private let workflowStore: ProductStore<WorkflowRecord>

    init(dataDirectory: URL) {
        agentStore = ProductStore(dataDirectory: dataDirectory, folder: "agents")
        workflowStore = ProductStore(dataDirectory: dataDirectory, folder: "workflows")
    }

    var agents: [AgentDefinition] { BuiltInAgents.all + customAgents.map(\.definition) }
    var workflows: [WorkflowDefinition] { BuiltInWorkflows.all + customWorkflows.map(\.definition) }

    func load() async {
        async let agents = agentStore.loadAll()
        async let workflows = workflowStore.loadAll()
        customAgents = await agents
        customWorkflows = await workflows
        isLoaded = true
    }

    func agentRecord(for definition: AgentDefinition) -> CustomAgentRecord? {
        customAgents.first { $0.definition.id == definition.id }
    }

    func workflowRecord(for definition: WorkflowDefinition) -> WorkflowRecord? {
        customWorkflows.first { $0.definition.id == definition.id }
    }

    @discardableResult
    func saveAgent(_ record: CustomAgentRecord) async -> CustomAgentRecord? {
        var copy = record
        copy.format = CustomAgentRecord.currentFormat
        copy.updatedAt = Date()
        do {
            try await agentStore.save(copy)
            await load()
            app?.sync.request()
            return copy
        } catch {
            lastError = String(describing: error)
            return nil
        }
    }

    @discardableResult
    func duplicate(_ definition: AgentDefinition) async -> CustomAgentRecord? {
        await saveAgent(CustomAgentRecord(
            name: "\(definition.name) copy", summary: definition.summary,
            instructions: definition.instructions, allowedTools: definition.allowedTools,
            difficulty: definition.difficulty, modelPolicy: definition.modelPolicy,
            behavior: definition.behavior, maximumHelpers: definition.maximumHelpers
        ))
    }

    func deleteAgent(_ id: UUID) async {
        do { try await agentStore.delete(id); await load(); app?.sync.request() }
        catch { lastError = String(describing: error) }
    }

    @discardableResult
    func saveWorkflow(_ record: WorkflowRecord) async -> WorkflowRecord? {
        var copy = record
        copy.format = WorkflowRecord.currentFormat
        copy.updatedAt = Date()
        do {
            try await workflowStore.save(copy)
            await load()
            app?.sync.request()
            return copy
        } catch {
            lastError = String(describing: error)
            return nil
        }
    }

    @discardableResult
    func duplicate(_ definition: WorkflowDefinition) async -> WorkflowRecord? {
        await saveWorkflow(WorkflowRecord(name: "\(definition.name) copy", summary: definition.summary, steps: definition.steps, isApproved: false))
    }

    func approve(_ record: WorkflowRecord) async {
        var copy = record
        copy.isApproved = true
        _ = await saveWorkflow(copy)
    }

    func deleteWorkflow(_ id: UUID) async {
        do { try await workflowStore.delete(id); await load(); app?.sync.request() }
        catch { lastError = String(describing: error) }
    }

    func run(_ workflow: WorkflowDefinition, request: String) async {
        guard workflow.isApproved else {
            lastError = "Approve this workflow before its first run."
            return
        }
        await app?.jobs.start(workflow: workflow, request: request, repo: app?.home.repo)
    }
}
