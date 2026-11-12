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
    @ObservationIgnored private let provisioningStore: ProductStore<AutonomousInstallationRecord>
    @ObservationIgnored private var watcher: Task<Void, Never>?
    @ObservationIgnored private var localRuns: [UUID: Task<Void, Never>] = [:]

    init(dataDirectory: URL) {
        store = JobStore(dataDirectory: dataDirectory)
        provisioningStore = ProductStore(dataDirectory: dataDirectory, folder: "autonomous-installations")
    }

    deinit {
        watcher?.cancel()
        localRuns.values.forEach { $0.cancel() }
    }

    var selectedJob: JobRecord? { jobs.first { $0.id == selectedJobID } }
    var activeCount: Int { jobs.filter { ![.done, .failed, .stopped].contains($0.status) }.count }

    func load() async {
        _ = try? await store.compactFinished()
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

    /// The chat decides what a request is, like Kiro: you type, and the app works out whether that
    /// is an answer, a repo change, or a multi-step job, and does it inside the chat.
    ///
    /// Deliberately conservative. A plain question must never start a workflow, so this returns nil
    /// unless the words clearly ask for multi-step work, and it returns nil whenever the Workflows
    /// switch is off. It never adds a second spending confirmation: a workflow is sub-agents running
    /// longer, so it starts the same way they do, and the existing spend limit and stop-and-ask
    /// setting still apply as they do everywhere else.
    func routedWorkflow(request: String, repo: ChatRepo?) -> WorkflowDefinition? {
        guard let app, app.settings.workflowsEnabled else { return nil }
        // The words are judged in AgentCore (`ChatRouting`), where the decision has unit tests.
        guard let id = ChatRouting.decide(request).workflowID else { return nil }
        return BuiltInWorkflows.named(id)
    }

    @discardableResult
    func start(request: String, repo: ChatRepo, workflow: WorkflowDefinition? = nil, additionalState: [String: JSONValue] = [:]) async -> JobRecord? {
        guard let app else { return nil }
        guard app.settings.autonomousEnabled else {
            lastError = "Autonomous is turned off in Settings. Turn it on to run repo jobs on your chat computer, or switch 'Where it runs' to 'On this phone'."
            return nil
        }
        guard !repo.ref.isGitLab else {
            // Jobs keep their record in the GitHub data repo and work with GitHub's checks.
            lastError = "\(repo.ref.fullName) is on GitLab. Jobs and preview builds need a GitHub repo; edit and save GitLab projects in the chat instead."
            return nil
        }
        guard let github = app.github.client else {
            lastError = "Connect GitHub in Settings before running a job on a repository."
            return nil
        }
        await app.sync.syncNow()
        guard let dataRepo = app.sync.repo else {
            lastError = "MAIPA-G needs its private data repo before Autonomous can start."
            return nil
        }
        // Jobs run on the owner's chat computer (owner rule, 11 November 2026: all agent work runs
        // on his Linux VM; GitHub only builds the app), so nothing is installed in the repo and no
        // repo secrets are set. Only a preview build still runs on GitHub Actions, because its
        // result is an Actions artifact.
        let isPreviewBuild = additionalState["previewBuild"]?.boolValue == true
        let installed: Bool
        if isPreviewBuild {
            let setup = AutonomousSetup(github: github)
            let reviewedRevision = Bundle.main.object(forInfoDictionaryKey: "MAIPAGReviewedRevision") as? String ?? ""
            installed = (try? await setup.isInstalled(in: repo.ref, ref: repo.defaultBranch, reviewedRevision: reviewedRevision)) == true
        } else {
            installed = true
        }
        let commit: String
        do { commit = try await github.resolveCommit(repo.ref, ref: repo.branch) }
        catch { lastError = app.github.describe(error); return nil }
        let ruleWorkspace = RepoWorkspace(repo: repo.ref, branch: repo.branch, commit: commit, github: github, store: app.snapshots)
        let rules = await GitHubChangeService(github: github).resolveRules(in: ruleWorkspace, directSaveSetting: app.settings.savesDirectly(to: repo.ref), requestText: request)
        var state: [String: JSONValue] = [
            "request": .string(request),
            "effectiveDirectSave": .bool(rules.directSave),
            "targetCommit": .string(commit),
            "buildExplicitlyRequested": .bool(UserRequestPolicy.explicitlyRequestsBuild(request)),
        ]
        state["repoRuleReason"] = rules.reason.map(JSONValue.string)
        for (key, value) in additionalState { state[key] = value }
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
            dataRepo: dataRepo,
            dataBranch: "main",
            dataInstallationID: app.github.installationID,
            directSave: rules.directSave,
            steps: [JobStepRecord(title: installed ? (isPreviewBuild ? "Waiting for GitHub" : "Waiting for your computer") : "Autonomous setup", status: installed ? .pending : .waiting)],
            questions: installed ? [] : [question]
        )
        do {
            _ = try await store.create(job)
            await reloadAndSync()
            selectedJobID = job.id
            // No Jobs screen pops up (owner, 11 November 2026: Kiro doesn't do jobs like this);
            // the work shows where it was started.
            if installed {
                do { try await dispatch(job) }
                catch let error as ComputerJobError { await failToStart(job.id, error.message); return job }
            }
            return job
        } catch {
            lastError = app.github.describe(error)
            return nil
        }
    }

    struct ComputerJobError: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    /// The computer couldn't take the job: it says why, and waits for Resume.
    private func failToStart(_ id: UUID, _ message: String) async {
        guard var job = (await store.all()).first(where: { $0.id == id }) else { return }
        job.status = .failed
        job.steps = [JobStepRecord(title: "Starting on your computer", status: .failed, startedAt: Date())]
        job.result = JobResult(summary: message)
        _ = try? await store.checkpoint(job)
        await reloadAndSync()
        lastError = message
    }

    @discardableResult
    func startPreviewBuild(repo: ChatRepo, project: WebPreviewProject, commit: String) async -> JobRecord? {
        guard let command = project.buildCommand else { return nil }
        let outputs = project.outputDirectories.map(JSONValue.string)
        return await start(
            request: "Build a private live-preview artifact from the selected saved commit.",
            repo: repo,
            additionalState: [
                "previewBuild": true,
                "previewBuildCommand": .string(command),
                "previewOutputDirectories": .array(outputs),
                "previewRoot": .string(project.rootPath),
                "previewCommit": .string(commit),
                "buildExplicitlyRequested": true,
            ]
        )
    }

    @discardableResult
    func start(
        workflow: WorkflowDefinition,
        request: String,
        repo: ChatRepo?,
        readOnlyRepo: ChatRepo? = nil,
        openJobsSheet: Bool = true
    ) async -> JobRecord? {
        if let repo { return await start(request: request, repo: repo, workflow: workflow) }
        guard let app else { return nil }
        guard app.openRouter.isSignedIn else {
            lastError = "Connect an AI provider in Settings before running an agent or workflow."
            return nil
        }
        let job = JobRecord(
            status: .running,
            title: workflow.name,
            state: workflowState(definition: workflow, request: request, readOnlyRepo: readOnlyRepo),
            steps: workflow.steps.flatMap(workflowJobSteps)
        )
        do {
            _ = try await store.create(job)
            jobs = await store.all()
            selectedJobID = job.id
            if openJobsSheet {
                app.sheet = .jobs
            }
            localRuns[job.id] = Task { [weak self] in
                await self?.runOnPhone(workflow: workflow, request: request, jobID: job.id)
                self?.localRuns[job.id] = nil
            }
            return job
        } catch {
            lastError = ErrorExplainer.explain(error).message
            return nil
        }
    }

    private func runOnPhone(workflow: WorkflowDefinition, request: String, jobID: UUID, answer: String? = nil) async {
        guard let app, app.openRouter.isSignedIn else { return }
        let aiClient = app.openRouter.client
        let hasOpenRouter = app.openRouter.hasOpenRouterKey
        let transport = app.transport
        let catalogue = app.openRouter.modelsByID
        let accountState = app.openRouter.accountState
        let login = app.github.login
        let recordStore = store
        let savedJob = await store.load(jobID)
        var readOnlyTools: [any AgentTool] = [WebSearchTool(transport: transport), ReadWebPageTool(transport: transport)]
        var specRepoContext: SystemPrompt.RepoContext?
        if let encodedRepo = savedJob?.state["readOnlyRepo"],
           let repoData = try? JSONCoding.encoder().encode(encodedRepo),
           let specRepo = try? JSONCoding.decoder().decode(ChatRepo.self, from: repoData),
           let github = app.github.client,
           let commit = try? await github.resolveCommit(specRepo.ref, ref: specRepo.branch) {
            let repoWorkspace = RepoWorkspace(repo: specRepo.ref, branch: specRepo.branch, commit: commit, github: github, store: app.snapshots)
            await repoWorkspace.prefetch()
            let readChanges = ChangeWorkspace(base: repoWorkspace)
            let rules = await GitHubChangeService(github: github).resolveRules(in: repoWorkspace, directSaveSetting: false)
            let specRepoTools: [any AgentTool] = [
                ListFilesTool(workspace: repoWorkspace, changes: readChanges),
                SearchCodeTool(workspace: repoWorkspace, changes: readChanges),
                ReadFileTool(workspace: repoWorkspace, changes: readChanges),
                ReadRepoFileTool(github: github),
                LoadRepoRulesTool(documents: rules.documents),
            ]
            readOnlyTools.append(contentsOf: specRepoTools)
            specRepoContext = SystemPrompt.RepoContext(
                ref: specRepo.ref,
                branch: specRepo.branch,
                commit: commit,
                isPrivate: specRepo.isPrivate,
                summary: app.github.repo(named: specRepo.ref.fullName)?.summary,
                ruleDocuments: rules.documents
            )
        }
        let sharedTools = readOnlyTools
        let sharedRepoContext = specRepoContext
        let runner: AgentExecutor.Runner = { invocation in
            var chat: Chat
            if let value = invocation.resumeState,
               let data = try? JSONCoding.encoder().encode(value),
               let saved = try? JSONCoding.decoder().decode(Chat.self, from: data) {
                chat = saved
                if let answer = invocation.answer, var turn = chat.lastAssistantTurn {
                    if let pending = turn.pendingQuestions {
                        turn.steps[pending.stepIndex].toolCalls[pending.callIndex].questions?.answers = [answer]
                    } else if answer == "Keep going", let spent = turn.spendCheck {
                        turn.approvedSpendUpTo = spent + max(invocation.spendLimit ?? 1, 0.01)
                        turn.spendCheck = nil
                    }
                    chat.messages[chat.messages.count - 1].assistantTurn = turn
                }
            } else {
                chat = Chat(title: invocation.definition.name)
                let completeTask = [invocation.definition.prompt(task: invocation.task), invocation.context].filter { !$0.isEmpty }.joined(separator: "\n\nContext:\n")
                chat.messages = [.user(completeTask), ChatMessage(body: .assistant(AssistantTurn()))]
            }
            let difficulty: TaskDifficulty = invocation.definition.modelPolicy == .fast ? .quick : invocation.definition.difficulty
            let effort = invocation.preferredEffort ?? .max
            let route: Route
            if let preferredID = invocation.preferredModelID, !preferredID.isEmpty, preferredID != ModelChoice.freeID {
                route = ModelRouter.route(choice: .model(preferredID), difficulty: difficulty, thinking: effort, account: accountState, catalogue: catalogue, openRouterAvailable: hasOpenRouter)
            } else if invocation.definition.modelPolicy == .differentFromPrimary {
                guard let distinct = ModelRouter.distinctRoute(avoiding: invocation.avoidModel, difficulty: difficulty, thinking: effort, account: accountState, catalogue: catalogue, openRouterAvailable: hasOpenRouter) else {
                    throw ToolInputError("A second eligible AI with a different model ID is not available for this review.")
                }
                route = distinct
            } else {
                route = ModelRouter.route(choice: .auto, difficulty: difficulty, thinking: effort, account: accountState, catalogue: catalogue, openRouterAvailable: hasOpenRouter)
            }
            let input = AgentTurnInput(
                chat: chat,
                route: route,
                systemPrompt: SystemPrompt.make(userLogin: login, repo: sharedRepoContext, agent: invocation.definition, workflowContext: invocation.context),
                tools: sharedTools + invocation.tools,
                spendLimit: invocation.spendLimit,
                requiresInitialSpendApproval: !route.isFree,
                agent: invocation.definition,
                autoApprove: true
            )
            let environment = AgentEnvironment(
                openRouter: aiClient,
                freeRoute: { ModelRouter.route(choice: .free, difficulty: difficulty, thinking: .medium, account: AccountState(), catalogue: catalogue, openRouterAvailable: hasOpenRouter) },
                onOutOfCredits: {}
            )
            var final: AssistantTurn?
            for await event in AgentLoop.run(input, environment: environment) {
                if case .updated(let turn, _) = event { final = turn }
            }
            let turn = final ?? AssistantTurn(status: .failed)
            let text = turn.steps.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n\n")
            if turn.status == .failed { throw ToolInputError(turn.failure?.message ?? "The agent did not finish.") }
            let pending = turn.pendingQuestions?.questions.questions.first.map { AgentExecutionQuestion(text: $0.text, options: $0.options) }
            let resumeState = (try? JSONCoding.encoder().encode(chat)).flatMap(JSONValue.parse)
            return AgentExecutionResult(
                output: text, model: turn.steps.last?.model,
                goalOutcome: AgentGoalOutcome.parse(text), cost: turn.usage.cost ?? 0,
                needsSpendingApproval: turn.spendCheck != nil, pendingQuestion: pending,
                resumeState: pending != nil || turn.spendCheck != nil ? resumeState : nil
            )
        }
        let restored = await store.workflowCheckpoint(jobID)
        let workflowSpendLimit = savedJob?.state["spendLimit"]?.doubleValue
        let engine = WorkflowEngine(
            definition: workflow,
            checkpoint: restored,
            agents: BuiltInAgents.allIncludingKiroSubagents + app.automations.customAgents.map(\.definition),
            spendLimit: workflowSpendLimit,
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
                    let summary = checkpoint.outputs.last?.text ?? "Workflow finished."
                    let passed = workflow.id.hasPrefix("spec-task:") ? summary.components(separatedBy: .newlines).contains { $0.trimmingCharacters(in: .whitespacesAndNewlines) == "GOAL_MET" } : nil
                    job.result = JobResult(summary: summary, verificationPassed: passed)
                case .waiting(_, let question):
                    job.status = .needsAnswer
                    job.questions = [JobQuestion(text: question.text, options: question.options, isApproval: ["Allow", "Start build", "Keep going", "Continue"].contains(question.options.first ?? ""))]
                case .cancelled:
                    job.status = .stopped
                case .failed(_, let message):
                    job.status = .failed
                    job.result = JobResult(summary: message)
                }
            }
            await reloadAndSync()
        } catch { lastError = ErrorExplainer.explain(error).message }
    }

    private func workflowState(definition: WorkflowDefinition, request: String, readOnlyRepo: ChatRepo? = nil) -> JSONValue {
        var value: [String: JSONValue] = ["request": .string(request)]
        if let app, app.settings.spendLimitOn { value["spendLimit"] = .number(app.settings.spendLimit) }
        if let data = try? JSONCoding.encoder().encode(definition), let encoded = JSONValue.parse(data) {
            value["workflowDefinition"] = encoded
        }
        if let readOnlyRepo,
           let repoData = try? JSONCoding.encoder().encode(readOnlyRepo),
           let encodedRepo = JSONValue.parse(repoData) {
            value["readOnlyRepo"] = encodedRepo
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
              let openRouterKey = app.openRouter.autonomousSecretKey,
              var job = jobs.first(where: { $0.id == id }), let repo = job.targetRepo else { return }
        do {
            job.status = .settingUp
            job.steps = [JobStepRecord(title: "Setting up Autonomous", status: .running, startedAt: Date())]
            job.questions = []
            job = try await store.checkpoint(job)
            jobs = await store.all()
            let setup = AutonomousSetup(github: github)
            var setupSecrets = [
                "MAIPAG_APP_ID": String(credentials.appID),
                "MAIPAG_APP_PRIVATE_KEY": credentials.privateKeyPEM,
                "OPENROUTER_API_KEY": openRouterKey,
            ]
            if let connectorSecrets = app.connectors.autonomousSecretsJSON() { setupSecrets["MAIPAG_MCP_SECRETS"] = connectorSecrets }
            let setupCommit = try await setup.install(
                in: repo,
                branch: job.defaultBranch ?? "main",
                secrets: setupSecrets,
                reviewedRevision: Bundle.main.object(forInfoDictionaryKey: "MAIPAGReviewedRevision") as? String ?? ""
            )
            let existingInstallations = await provisioningStore.loadAll()
            let record = existingInstallations.first(where: { $0.repo == repo }).map { existing -> AutonomousInstallationRecord in
                var copy = existing
                copy.managedSecrets = Set(setupSecrets.keys)
                copy.reviewedRevision = Bundle.main.object(forInfoDictionaryKey: "MAIPAGReviewedRevision") as? String ?? ""
                copy.updatedAt = Date()
                return copy
            } ?? AutonomousInstallationRecord(
                repo: repo,
                managedSecrets: Set(setupSecrets.keys),
                reviewedRevision: Bundle.main.object(forInfoDictionaryKey: "MAIPAGReviewedRevision") as? String ?? ""
            )
            try await provisioningStore.save(record)
            job.recordAutonomousSetupCommit(setupCommit)
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
            } catch { lastError = ErrorExplainer.explain(error).message }
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
            await stopOnComputer(job)
            await reloadAndSync()
        } catch { lastError = ErrorExplainer.explain(error).message }
    }

    func delete(_ id: UUID) async {
        guard let app, let job = jobs.first(where: { $0.id == id }) else { return }
        localRuns[id]?.cancel()
        localRuns[id] = nil
        do {
            if ![.done, .failed, .stopped].contains(job.status) {
                _ = try await store.stop(id)
                await reloadAndSync()
                await stopOnComputer(job)
                if let runID = job.workflowRunID, let repo = job.targetRepo, let github = app.github.client {
                    try? await github.cancelWorkflowRun(repo, runID: runID)
                    // Let GitHub stop the runner before deleting the shared record, otherwise its
                    // final checkpoint could bring the deleted job straight back.
                    for _ in 0..<20 {
                        if let run = try? await github.workflowRun(repo, runID: runID), run.status == "completed" { break }
                        try? await Task.sleep(nanoseconds: 500_000_000)
                    }
                }
            }
            try await store.delete(id)
            if selectedJobID == id { selectedJobID = nil }
            jobs = await store.all()
            // One save, not two: a request here as well started a second pass straight after.
            await app.sync.syncNow()
        } catch { lastError = ErrorExplainer.explain(error).message }
    }

    func restart(_ id: UUID) async {
        await stop(id)
        await resume(id)
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
            } catch { lastError = ErrorExplainer.explain(error).message }
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
            try await github.deleteBranchIfMAIPAG(repo, branch: pull.headBranch)
            job.result?.summary += GitHubClient.isMAIPAGBranch(pull.headBranch)
                ? "\n\nAdded the pull request and removed its side branch."
                : "\n\nAdded the pull request. Your branch \(pull.headBranch) was kept."
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
            try await github.deleteBranchIfMAIPAG(repo, branch: pull.headBranch)
            job.result?.summary += GitHubClient.isMAIPAGBranch(pull.headBranch)
                ? "\n\nClosed the pull request and removed its side branch."
                : "\n\nClosed the pull request. Your branch \(pull.headBranch) was kept."
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
        await refreshComputerJobTokens()
        for job in jobs where before[job.id] != job.status && (job.status == .done || job.status == .needsAnswer || job.status == .needsApproval) {
            let needs = job.status == .needsAnswer || job.status == .needsApproval
            app.notifications.post(
                title: needs ? "MAIPA-G needs you" : "MAIPA-G finished",
                body: job.title,
                enabled: app.settings.notificationsOn
            )
        }
    }

    /// Jobs run on the chat computer now (owner rule, 11 November 2026), so app updates no longer
    /// rewrite `.github/workflows/maipa-g.yml` in repos. A preview build that finds an older one
    /// asks to set it up again, as on first use.
    func updateAutonomousWorkflows() async {}

    func reconcileAutonomousConnectorSecrets() async {
        guard let app, let github = app.github.client else { return }
        let records = await provisioningStore.loadAll()
        var failures: [String] = []
        for var record in records {
            do {
                if let value = app.connectors.autonomousSecretsJSON() {
                    try await github.putActionsSecret(record.repo, name: "MAIPAG_MCP_SECRETS", value: value)
                    record.managedSecrets.insert("MAIPAG_MCP_SECRETS")
                } else {
                    try await github.deleteActionsSecret(record.repo, name: "MAIPAG_MCP_SECRETS")
                    record.managedSecrets.remove("MAIPAG_MCP_SECRETS")
                }
                record.updatedAt = Date()
                try await provisioningStore.save(record)
            } catch {
                failures.append("\(record.repo.fullName): \(ErrorExplainer.explain(error).message)")
            }
        }
        lastError = failures.isEmpty ? nil : "Autonomous secret cleanup failed for " + failures.joined(separator: "; ")
    }

    func cleanupAllAutonomousSecrets() async {
        guard let app, let github = app.github.client else { return }
        let known = Set(["MAIPAG_APP_ID", "MAIPAG_APP_PRIVATE_KEY", "OPENROUTER_API_KEY", "MAIPAG_MCP_SECRETS"])
        let records = await provisioningStore.loadAll()
        var failures: [String] = []
        for record in records {
            var failed = false
            for name in record.managedSecrets.union(known) {
                do { try await github.deleteActionsSecret(record.repo, name: name) }
                catch {
                    failed = true
                    failures.append("\(record.repo.fullName) / \(name): \(ErrorExplainer.explain(error).message)")
                }
            }
            if !failed { try? await provisioningStore.delete(record.id) }
        }
        lastError = failures.isEmpty ? nil : "Autonomous secret cleanup failed for " + failures.joined(separator: "; ")
    }

    /// Repos set up by builds before the record existed are found by their secret names and
    /// caller workflow, and added so later cleanups and sign-in changes reach them too.
    func migrateAutonomousLedger() async {
        guard let app, let github = app.github.client else { return }
        let repos = app.github.repos.map(\.ref)
        var branches: [RepoRef: String] = [:]
        for repo in app.github.repos { branches[repo.ref] = repo.defaultBranch }
        let defaultBranches = branches
        let existing = await provisioningStore.loadAll()
        let result = await AutonomousSecretLedger.migrate(
            repos: repos, existing: existing,
            secretNames: { repo in try await github.actionsSecretNames(repo) },
            // A missing caller file is an expected "no"; the secret-name check above already
            // reported any access problem for this repo.
            hasCaller: { repo in (try? await github.fileContents(repo, path: AutonomousSetup.callerPath, ref: defaultBranches[repo] ?? "main")) != nil }
        )
        for record in result.added {
            do { try await provisioningStore.save(record) }
            catch { lastError = "Couldn't record \(record.repo.fullName)'s Autonomous secrets: \(ErrorExplainer.explain(error).message)" }
        }
        if !result.added.isEmpty { app.sync.request() }
        if !result.failures.isEmpty {
            lastError = "Couldn't check these repos for old Autonomous secrets: " + result.failures.prefix(5).joined(separator: "; ") + ". Tap Find repos with old Autonomous secrets to retry."
        }
        UserDefaults.standard.set(true, forKey: Self.ledgerMigratedKey)
    }

    static let ledgerMigratedKey = "autonomousLedgerMigrated"

    /// After the OpenRouter key or the GitHub app's key changes, every recorded repo gets the new
    /// values, so no repo keeps a revoked or old credential.
    ///
    /// Stops dead when Autonomous is off. This used to run regardless of the switch: it blanked the
    /// secret values but still rotated, and rotating writes `.github/workflows/maipa-g.yml`, so a
    /// repo got an Autonomous workflow committed into it while the feature was off. Off now means
    /// nothing is written anywhere.
    func rotateAutonomousSecrets() async {
        guard let app, let github = app.github.client, let credentials = app.github.credentials else { return }
        guard app.settings.autonomousEnabled else { return }
        let records = await provisioningStore.loadAll()
        guard !records.isEmpty else { return }
        var values = [
            "MAIPAG_APP_ID": String(credentials.appID),
            "MAIPAG_APP_PRIVATE_KEY": credentials.privateKeyPEM,
        ]
        if let key = app.openRouter.autonomousSecretKey { values["OPENROUTER_API_KEY"] = key }
        if let connectors = app.connectors.autonomousSecretsJSON() { values["MAIPAG_MCP_SECRETS"] = connectors }
        let result = await AutonomousSecretLedger.rotate(
            records: records, values: values,
            put: { repo, name, value in try await github.putActionsSecret(repo, name: name, value: value) },
            delete: { repo, name in try await github.deleteActionsSecret(repo, name: name) }
        )
        for record in result.records {
            do { try await provisioningStore.save(record) }
            catch { lastError = "Couldn't update the record for \(record.repo.fullName): \(ErrorExplainer.explain(error).message)" }
        }
        app.sync.request()
        lastError = result.failures.isEmpty ? nil : "Updating Autonomous secrets failed for " + result.failures.joined(separator: "; ") + ". Retry from Settings."
    }

    func retryPendingSecretCleanup() async {
        if app?.openRouter.isSignedIn == true, app?.settings.autonomousEnabled == true { await rotateAutonomousSecrets() }
        else { await cleanupAllAutonomousSecrets() }
    }

    private func dispatch(_ job: JobRecord) async throws {
        guard job.state["previewBuild"]?.boolValue == true else {
            try await dispatchToComputer(job)
            return
        }
        guard let app, let github = app.github.client, let repo = job.targetRepo else { return }
        await app.sync.syncNow()
        if let connectorSecrets = app.connectors.autonomousSecretsJSON() {
            try await github.putActionsSecret(repo, name: "MAIPAG_MCP_SECRETS", value: connectorSecrets)
        } else {
            try await github.deleteActionsSecret(repo, name: "MAIPAG_MCP_SECRETS")
        }
        let dispatchRef = job.state["previewBuild"]?.boolValue == true ? (job.targetRef ?? job.defaultBranch ?? "main") : (job.defaultBranch ?? "main")
        guard let inputs = job.autonomousWorkflowInputs else { throw ToolInputError("This job is missing its private data-repository identity.") }
        var dispatched = false
        var lastDispatchError: Error?
        // A caller workflow committed during first-use setup takes a few seconds to appear in
        // GitHub's workflow index. Retry that exact temporary 404/422 instead of leaving a job
        // looking stuck until someone manually resumes it.
        for attempt in 1...10 {
            do {
                try await github.dispatchWorkflow(
                    repo,
                    workflow: "maipa-g.yml",
                    ref: dispatchRef,
                    inputs: inputs
                )
                dispatched = true
                break
            } catch let error as GitHubAPIError where [404, 422].contains(error.status) {
                lastDispatchError = error
                if attempt < 10 { try await Task.sleep(nanoseconds: UInt64(min(attempt, 4)) * 1_000_000_000) }
            }
        }
        if !dispatched { throw lastDispatchError ?? ToolInputError("GitHub did not start this job.") }
        var updated = job
        updated.status = .running
        updated.steps = [JobStepRecord(title: "Starting on GitHub", status: .running, startedAt: Date())]
        _ = try await store.checkpoint(updated)
        jobs = await store.all()
        app.sync.request()
    }

    /// Starts the job with MAIPA-G's runner on the chat computer. Its record and checkpoints stay
    /// in the private data repo, exactly as when it ran on GitHub, so following it is unchanged.
    private func dispatchToComputer(_ job: JobRecord) async throws {
        guard let app, let repo = job.targetRepo, let dataRepo = job.dataRepo else { return }
        await app.sync.syncNow()
        let vm: VMControl
        switch await ComputerRuns.prepare(app: app) {
        case .ready(let ready): vm = ready
        case .unavailable(let reason):
            throw ComputerJobError(message: "Jobs run on your chat computer, and it can't take this one yet: \(reason). Tap Resume once it is ready.")
        }
        guard let revision = ComputerRuns.revision else { throw ComputerJobError(message: "This app build doesn't say which runner it needs.") }
        guard let token = await ComputerRuns.githubToken(app: app) else {
            throw ComputerJobError(message: "GitHub didn't give MAIPA-G a token for this job. Check GitHub in Settings, then tap Resume.")
        }
        let request = VMJobRequest(
            jobID: job.id, targetRepository: repo, targetRef: job.targetRef ?? job.defaultBranch ?? "main",
            dataRepository: dataRepo, dataBranch: job.dataBranch
        )
        let id = VMRun.jobRunID(job.id)
        // A resumed job starts from its checkpoint in a fresh folder.
        try? await vm.stop(id: id)
        try? await vm.remove(id: id)
        do {
            try await vm.start(id: id, mode: .job, revision: revision, request: try VMCoding.pack(request), secrets: ComputerRuns.secrets(app: app, githubToken: token))
        } catch {
            throw ComputerJobError(message: "Handing the job to your computer failed: \(ErrorExplainer.explain(error).message)")
        }
        jobTokenHandovers[job.id] = Date()
        var updated = job
        updated.status = .running
        updated.steps = [JobStepRecord(title: "Starting on your computer", status: .running, startedAt: Date())]
        _ = try await store.checkpoint(updated)
        jobs = await store.all()
        app.sync.request()
    }

    @ObservationIgnored private var jobTokenHandovers: [UUID: Date] = [:]

    private func stopOnComputer(_ job: JobRecord) async {
        guard job.state["previewBuild"]?.boolValue != true, job.targetRepo != nil,
              let control = app?.connectors.computerControl() else { return }
        let vm = VMControl(computer: control)
        try? await vm.stop(id: VMRun.jobRunID(job.id))
    }

    /// GitHub tokens last about an hour. While the app is open, jobs on the computer get a fresh
    /// one every 40 minutes.
    private func refreshComputerJobTokens() async {
        guard let app else { return }
        let running = jobs.filter { [.running, .queued, .settingUp].contains($0.status) && $0.targetRepo != nil && $0.state["previewBuild"]?.boolValue != true }
        let due = running.filter { Date().timeIntervalSince(jobTokenHandovers[$0.id] ?? .distantPast) > 40 * 60 }
        guard !due.isEmpty, let control = app.connectors.computerControl(), let token = await ComputerRuns.githubToken(app: app) else { return }
        let vm = VMControl(computer: control)
        for job in due {
            if (try? await vm.handOverToken(id: VMRun.jobRunID(job.id), token: token)) != nil { jobTokenHandovers[job.id] = Date() }
        }
    }

    private func reloadAndSync() async {
        jobs = await store.all()
        // syncNow alone: it saves now, or after the pass already running. A request as well
        // started a second pass for the same change.
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
