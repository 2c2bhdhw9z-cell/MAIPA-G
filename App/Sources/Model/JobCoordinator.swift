import AgentCore
import Foundation
import Observation

@MainActor
@Observable
final class JobCoordinator {
    private(set) var jobs: [JobRecord] = []
    private(set) var isRefreshing = false
    private(set) var lastError: String?
    private(set) var selectedJobID: UUID?

    @ObservationIgnored weak var app: AppModel?
    @ObservationIgnored private let store: JobStore
    @ObservationIgnored private var watcher: Task<Void, Never>?
    @ObservationIgnored private var localRuns: [UUID: Task<Void, Never>] = [:]

    init(dataDirectory: URL) {
        store = JobStore(dataDirectory: dataDirectory)
    }

    deinit {
        watcher?.cancel()
        localRuns.values.forEach { $0.cancel() }
    }

    var selectedJob: JobRecord? { jobs.first { $0.id == selectedJobID } }
    var activeCount: Int { jobs.filter { ![.done, .failed, .stopped].contains($0.status) }.count }

    func load() async {
        jobs = await store.all()
        startWatching()
    }

    func preview(_ records: [JobRecord]) {
        jobs = records
        selectedJobID = records.first?.id
    }

    func show(_ id: UUID? = nil) {
        selectedJobID = id ?? jobs.first?.id
        app?.sheet = .jobs
    }

    /// Repo-less work deliberately returns false and stays in the existing on-phone chat.
    func shouldRunAutonomously(request: String, repo: ChatRepo?, explicitlyEnabled: Bool) -> Bool {
        guard repo != nil, let app else { return false }
        if explicitlyEnabled { return true }
        switch app.settings.workflowPolicy {
        case .whenAsked: return false
        case .everything: return true
        case .bigJobs: return TaskDifficulty.estimate(request, hasRepo: true) == .hard
        }
    }

    @discardableResult
    func start(request: String, repo: ChatRepo, workflow: WorkflowDefinition? = nil) async -> JobRecord? {
        guard let app, let github = app.github.client else { return nil }
        let setup = AutonomousSetup(github: github)
        let installed = (try? await setup.isInstalled(in: repo.ref, ref: repo.defaultBranch)) == true
        var state: [String: JSONValue] = ["request": .string(request)]
        if let workflow,
           let data = try? JSONCoding.encoder().encode(workflow),
           let value = JSONValue.parse(data) {
            state["workflowDefinition"] = value
            let used = Set(workflow.steps.flatMap(Self.agentIDs))
            let custom = app.automations.customAgents.filter { used.contains($0.definition.id) }.compactMap { record -> JSONValue? in
                (try? JSONCoding.encoder().encode(record)).flatMap(JSONValue.parse)
            }
            if !custom.isEmpty { state["customAgents"] = .array(custom) }
        }
        if let botName = app.github.credentials?.botName { state["botName"] = .string(botName) }
        if app.settings.spendLimitOn { state["spendLimit"] = .number(app.settings.spendLimit) }
        let stdioConnectors = app.connectors.connected.filter { $0.kind == .stdio }.compactMap { connector -> JSONValue? in
            (try? JSONCoding.encoder().encode(connector)).flatMap(JSONValue.parse)
        }
        if !stdioConnectors.isEmpty { state["stdioConnectors"] = .array(stdioConnectors) }
        let question = JobQuestion(
            text: "Set up Autonomous in \(repo.ref.name)?",
            options: ["Set up and start", "Not now"],
            isApproval: true
        )
        let job = JobRecord(
            status: installed ? .queued : .needsApproval,
            title: ChatSession.provisionalTitle(request),
            state: .object(state),
            targetRepo: repo.ref,
            targetRef: repo.branch,
            defaultBranch: repo.defaultBranch,
            directSave: app.settings.savesDirectly(to: repo.ref),
            steps: [JobStepRecord(title: installed ? "Waiting for GitHub" : "Autonomous setup", status: installed ? .pending : .waiting)],
            questions: installed ? [] : [question]
        )
        do {
            _ = try await store.create(job)
            await reloadAndSync()
            selectedJobID = job.id
            app.sheet = .jobs
            if installed { try await dispatch(job) }
            return job
        } catch {
            lastError = app.github.describe(error)
            return nil
        }
    }

    @discardableResult
    func start(workflow: WorkflowDefinition, request: String, repo: ChatRepo?) async -> JobRecord? {
        if let repo { return await start(request: request, repo: repo, workflow: workflow) }
        guard let app, app.openRouter.apiKey != nil else { return nil }
        let job = JobRecord(
            status: .running,
            title: workflow.name,
            state: workflowState(definition: workflow, request: request),
            steps: workflow.steps.flatMap(workflowJobSteps)
        )
        do {
            _ = try await store.create(job)
            jobs = await store.all()
            selectedJobID = job.id
            app.sheet = .jobs
            localRuns[job.id] = Task { [weak self] in
                await self?.runOnPhone(workflow: workflow, request: request, jobID: job.id)
                self?.localRuns[job.id] = nil
            }
            return job
        } catch {
            lastError = String(describing: error)
            return nil
        }
    }

    private func runOnPhone(workflow: WorkflowDefinition, request: String, jobID: UUID, answer: String? = nil) async {
        guard let app, let apiKey = app.openRouter.apiKey else { return }
        let transport = app.transport
        let catalogue = app.openRouter.modelsByID
        let accountState = app.openRouter.accountState
        let login = app.github.login
        let recordStore = store
        let runner: AgentExecutor.Runner = { invocation in
            var chat = Chat(title: invocation.definition.name)
            let completeTask = [invocation.definition.prompt(task: invocation.task), invocation.context].filter { !$0.isEmpty }.joined(separator: "\n\nContext:\n")
            chat.messages = [.user(completeTask), ChatMessage(body: .assistant(AssistantTurn()))]
            let difficulty: TaskDifficulty = invocation.definition.modelPolicy == .fast ? .quick : invocation.definition.difficulty
            let choice: ModelChoice = invocation.definition.modelPolicy == .differentFromPrimary ? .free : .auto
            let route = ModelRouter.route(choice: choice, difficulty: difficulty, thinking: .medium, account: accountState, catalogue: catalogue)
            let input = AgentTurnInput(
                chat: chat,
                route: route,
                systemPrompt: SystemPrompt.make(userLogin: login, repo: nil, agent: invocation.definition, workflowContext: invocation.context),
                tools: [WebSearchTool(transport: transport), ReadWebPageTool(transport: transport)],
                agent: invocation.definition
            )
            let environment = AgentEnvironment(
                openRouter: OpenRouterClient(transport: transport, apiKey: apiKey),
                freeRoute: { ModelRouter.route(choice: .free, difficulty: difficulty, thinking: .medium, account: AccountState(), catalogue: catalogue) },
                onOutOfCredits: {}
            )
            var final: AssistantTurn?
            for await event in AgentLoop.run(input, environment: environment) {
                if case .updated(let turn, _) = event { final = turn }
            }
            let turn = final ?? AssistantTurn(status: .failed)
            let text = turn.steps.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n\n")
            if turn.status == .failed { throw ToolInputError(turn.failure?.message ?? "The agent did not finish.") }
            return AgentExecutionResult(
                output: text, model: turn.steps.last?.model,
                goalMet: text.uppercased().contains("GOAL_MET"), cost: turn.usage.cost ?? 0
            )
        }
        let restored = await store.workflowCheckpoint(jobID)
        let engine = WorkflowEngine(
            definition: workflow,
            checkpoint: restored,
            agents: BuiltInAgents.all + app.automations.customAgents.map(\.definition),
            runner: runner,
            checkpointer: { checkpoint in _ = try await recordStore.checkpointWorkflow(jobID, checkpoint: checkpoint) }
        )
        if let answer, let pending = restored?.pendingQuestion {
            try? await engine.answer(nodeID: pending.nodeID, answer: answer)
        }
        let outcome = await engine.run(request: request)
        let checkpoint: WorkflowCheckpoint
        switch outcome {
        case .completed(let value), .cancelled(let value), .failed(let value, _): checkpoint = value
        case .waiting(let value, _): checkpoint = value
        }
        let nodes = workflow.steps.flatMap(flattenWorkflowNodes)
        let previousSteps = await store.load(jobID)?.steps ?? []
        let stepRecords = nodes.enumerated().map { index, node -> JobStepRecord in
            let status: JobStepRecord.Status
            switch checkpoint.statuses[node.id] {
            case .completed: status = .done
            case .running: status = .running
            case .waiting: status = .waiting
            case .failed: status = .failed
            case .cancelled: status = .stopped
            default: status = .pending
            }
            return JobStepRecord(id: index < previousSteps.count ? previousSteps[index].id : UUID(), title: node.title, status: status)
        }
        do {
            _ = try await store.update(jobID) { job in
                job.cumulativeCost = checkpoint.cumulativeCost
                job.steps = stepRecords
                switch outcome {
                case .completed:
                    job.status = .done
                    job.result = JobResult(summary: checkpoint.outputs.last?.text ?? "Workflow finished.")
                case .waiting(_, let question):
                    job.status = .needsAnswer
                    job.questions = [JobQuestion(text: question.text, options: question.options)]
                case .cancelled:
                    job.status = .stopped
                case .failed(_, let message):
                    job.status = .failed
                    job.result = JobResult(summary: message)
                }
            }
            await reloadAndSync()
        } catch { lastError = String(describing: error) }
    }

    private func workflowState(definition: WorkflowDefinition, request: String) -> JSONValue {
        var value: [String: JSONValue] = ["request": .string(request)]
        if let data = try? JSONCoding.encoder().encode(definition), let encoded = JSONValue.parse(data) {
            value["workflowDefinition"] = encoded
        }
        return .object(value)
    }

    private func workflowJobSteps(_ node: WorkflowNode) -> [JobStepRecord] {
        flattenWorkflowNodes(node).map { JobStepRecord(title: $0.title) }
    }

    private func flattenWorkflowNodes(_ node: WorkflowNode) -> [WorkflowNode] {
        [node] + node.children.flatMap(flattenWorkflowNodes)
    }

    /// Called only by the visible “Set up and start” button in Jobs.
    func confirmSetupAndStart(_ id: UUID) async {
        guard let app, let github = app.github.client, let credentials = app.github.credentials,
              let openRouterKey = app.openRouter.apiKey,
              var job = jobs.first(where: { $0.id == id }), let repo = job.targetRepo else { return }
        do {
            job.status = .settingUp
            job.steps = [JobStepRecord(title: "Setting up Autonomous", status: .running, startedAt: Date())]
            job.questions = []
            job = try await store.checkpoint(job)
            jobs = await store.all()
            let setup = AutonomousSetup(github: github)
            _ = try await setup.install(
                in: repo,
                branch: job.defaultBranch ?? "main",
                secrets: [
                    "MAIPAG_APP_ID": String(credentials.appID),
                    "MAIPAG_APP_PRIVATE_KEY": credentials.privateKeyPEM,
                    "OPENROUTER_API_KEY": openRouterKey,
                ]
            )
            job.status = .queued
            job.steps = [JobStepRecord(title: "Waiting for GitHub", status: .pending)]
            job = try await store.checkpoint(job)
            await reloadAndSync()
            try await dispatch(job)
        } catch {
            job.status = .failed
            job.result = JobResult(summary: "Autonomous setup didn't finish.")
            _ = try? await store.checkpoint(job)
            jobs = await store.all()
            lastError = app.github.describe(error)
        }
    }

    func answer(_ jobID: UUID, questionID: UUID, answer: String) async {
        guard let app else { return }
        if let job = jobs.first(where: { $0.id == jobID }), job.targetRepo == nil,
           let value = job.state["workflowDefinition"],
           let data = try? JSONCoding.encoder().encode(value),
           let workflow = try? JSONCoding.decoder().decode(WorkflowDefinition.self, from: data) {
            do {
                _ = try await store.answer(jobID, questionID: questionID, answer: answer)
                Task { [weak self] in await self?.runOnPhone(workflow: workflow, request: job.state["request"]?.stringValue ?? "", jobID: jobID, answer: answer) }
            } catch { lastError = String(describing: error) }
            return
        }
        do {
            if answer == "Set up and start" {
                await confirmSetupAndStart(jobID)
                return
            }
            if answer == "Not now" || answer == "Stop" {
                _ = try await store.stop(jobID)
            } else {
                let job = try await store.answer(jobID, questionID: questionID, answer: answer)
                await reloadAndSync()
                try await dispatch(job)
            }
            jobs = await store.all()
        } catch { lastError = app.github.describe(error) }
    }

    func stop(_ id: UUID) async {
        guard let app else { return }
        localRuns[id]?.cancel()
        localRuns[id] = nil
        do {
            let job = try await store.stop(id)
            if let run = job.workflowRunID, let repo = job.targetRepo, let github = app.github.client {
                try? await github.cancelWorkflowRun(repo, runID: run)
            }
            await reloadAndSync()
        } catch { lastError = String(describing: error) }
    }

    func resume(_ id: UUID) async {
        guard let app else { return }
        if let job = jobs.first(where: { $0.id == id }), job.targetRepo == nil,
           let value = job.state["workflowDefinition"],
           let data = try? JSONCoding.encoder().encode(value),
           let workflow = try? JSONCoding.decoder().decode(WorkflowDefinition.self, from: data) {
            do {
                _ = try await store.resume(id)
                localRuns[id] = Task { [weak self] in
                    await self?.runOnPhone(workflow: workflow, request: job.state["request"]?.stringValue ?? "", jobID: id)
                    self?.localRuns[id] = nil
                }
            } catch { lastError = String(describing: error) }
            return
        }
        do {
            let job = try await store.resume(id)
            await reloadAndSync()
            try await dispatch(job)
        } catch { lastError = app.github.describe(error) }
    }

    func addIt(_ id: UUID) async {
        guard let app, let github = app.github.client, var job = jobs.first(where: { $0.id == id }),
              let repo = job.targetRepo, let pull = job.result?.pullRequest else { return }
        do {
            try await github.mergePullRequest(repo, number: pull.number, title: pull.title)
            try await github.deleteBranch(repo, branch: pull.headBranch)
            job.result?.summary += "\n\nAdded the pull request and removed its side branch."
            job.result?.pullRequest = nil
            _ = try await store.checkpoint(job)
            await reloadAndSync()
        } catch { lastError = app.github.describe(error) }
    }

    func throwAway(_ id: UUID) async {
        guard let app, let github = app.github.client, var job = jobs.first(where: { $0.id == id }),
              let repo = job.targetRepo, let pull = job.result?.pullRequest else { return }
        do {
            _ = try await github.closePullRequest(repo, number: pull.number)
            try await github.deleteBranch(repo, branch: pull.headBranch)
            job.result?.summary += "\n\nClosed the pull request and removed its side branch."
            job.result?.pullRequest = nil
            _ = try await store.checkpoint(job)
            await reloadAndSync()
        } catch { lastError = app.github.describe(error) }
    }

    /// Builders must pass true only when the user's request expressly asks to start a build.
    func dispatchBuild(repo: RepoRef, workflow: String, ref: String, explicitlyRequested: Bool) async throws {
        guard explicitlyRequested, let github = app?.github.client else { return }
        try await github.dispatchWorkflow(repo, workflow: workflow, ref: ref)
    }

    func refresh() async {
        guard !isRefreshing, let app else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        await app.sync.syncNow()
        let before = Dictionary(uniqueKeysWithValues: jobs.map { ($0.id, $0.status) })
        jobs = await store.all()
        for job in jobs where before[job.id] != job.status && (job.status == .done || job.status == .needsAnswer || job.status == .needsApproval) {
            let needs = job.status == .needsAnswer || job.status == .needsApproval
            app.notifications.post(
                title: needs ? "MAIPA-G needs you" : "MAIPA-G finished",
                body: job.title,
                enabled: app.settings.notificationsOn
            )
        }
    }

    private func dispatch(_ job: JobRecord) async throws {
        guard let app, let github = app.github.client, let repo = job.targetRepo else { return }
        await app.sync.syncNow()
        try await github.dispatchWorkflow(
            repo,
            workflow: "maipa-g.yml",
            ref: job.defaultBranch ?? "main",
            inputs: ["job_id": job.id.uuidString.lowercased()]
        )
        var updated = job
        updated.status = .running
        updated.steps = [JobStepRecord(title: "Starting on GitHub", status: .running, startedAt: Date())]
        _ = try await store.checkpoint(updated)
        jobs = await store.all()
        app.sync.request()
    }

    private func reloadAndSync() async {
        jobs = await store.all()
        app?.sync.request(after: 0.1)
        await app?.sync.syncNow()
    }

    private static func agentIDs(_ node: WorkflowNode) -> [String] {
        (node.agentID.map { [$0] } ?? []) + node.children.flatMap(agentIDs)
    }

    private func startWatching() {
        watcher?.cancel()
        watcher = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                guard !Task.isCancelled else { return }
                await self?.refresh()
            }
        }
    }
}
