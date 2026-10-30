import AgentCore
import Foundation
import Observation

@MainActor
@Observable
final class AutomationLibrary {
    private(set) var customAgents: [CustomAgentRecord] = []
    private(set) var customWorkflows: [WorkflowRecord] = []
    private(set) var isLoaded = false
    private(set) var isMakingWorkflow = false
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
            lastError = ErrorExplainer.explain(error).message
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
        guard let record = customAgents.first(where: { $0.id == id }) else { return }
        do {
            try await app?.trash.move(id: id, kind: .agent, title: record.definition.name, originalPath: await agentStore.relativePath(for: id))
            await load(); app?.sync.request()
        } catch { lastError = ErrorExplainer.explain(error).message }
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
            lastError = ErrorExplainer.explain(error).message
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
        guard let record = customWorkflows.first(where: { $0.id == id }) else { return }
        do {
            try await app?.trash.move(id: id, kind: .workflow, title: record.definition.name, originalPath: await workflowStore.relativePath(for: id))
            await load(); app?.sync.request()
        } catch { lastError = ErrorExplainer.explain(error).message }
    }

    func makeWorkflow(description: String) async -> WorkflowRecord? {
        guard !isMakingWorkflow, let app, let apiKey = app.openRouter.apiKey,
              let maker = BuiltInAgents.named("workflow-maker") else { return nil }
        isMakingWorkflow = true
        lastError = nil
        defer { isMakingWorkflow = false }
        let definitions = agents
        let prompt = WorkflowDraftBuilder.generationPrompt(description: description, agents: definitions)
        var chat = Chat(title: "Workflow maker")
        chat.messages = [.user(prompt), ChatMessage(body: .assistant(AssistantTurn()))]
        let catalogue = app.openRouter.modelsByID
        let route = ModelRouter.route(choice: .auto, difficulty: .hard, thinking: .medium, account: app.openRouter.accountState, catalogue: catalogue)
        let input = AgentTurnInput(
            chat: chat, route: route,
            systemPrompt: SystemPrompt.make(userLogin: app.github.login, repo: nil, agent: maker),
            tools: [], allowTools: false,
            spendLimit: app.settings.spendLimitOn ? app.settings.spendLimit : nil,
            agent: maker
        )
        let environment = AgentEnvironment(
            openRouter: OpenRouterClient(transport: app.transport, apiKey: apiKey),
            freeRoute: { ModelRouter.route(choice: .free, difficulty: .hard, thinking: .medium, account: AccountState(), catalogue: catalogue) },
            onOutOfCredits: {}
        )
        var final: AssistantTurn?
        for await event in AgentLoop.run(input, environment: environment) {
            if case .updated(let turn, _) = event { final = turn }
        }
        do {
            guard let turn = final, turn.status == .done else { throw ToolInputError(final?.failure?.message ?? "Workflow maker did not finish.") }
            let text = turn.steps.map(\.text).joined(separator: "\n")
            let draft = try WorkflowDraftBuilder.generatedDraft(from: text, agentIDs: Set(definitions.map(\.id)))
            return WorkflowRecord(definition: draft)
        } catch {
            lastError = ErrorExplainer.explain(error).message
            return nil
        }
    }

    func run(_ workflow: WorkflowDefinition, request: String) async {
        guard workflow.isApproved else {
            lastError = "Approve this workflow before its first run."
            return
        }
        await app?.jobs.start(workflow: workflow, request: request, repo: app?.home.repo)
    }
}
