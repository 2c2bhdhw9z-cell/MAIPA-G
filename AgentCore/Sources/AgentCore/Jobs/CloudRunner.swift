import Foundation

public struct CloudRunnerConfiguration: Sendable {
    public var jobID: UUID
    public var targetRepository: RepoRef
    public var workspace: URL
    /// Immutable shared-runner checkout. It must not be inside the model-controlled target repo.
    public var trustedRunnerDirectory: URL
    /// Captured before untrusted work begins, so later target commands cannot replace it.
    public var ipaChecker: Data
    public var targetToken: String
    public var dataToken: String
    public var dataRepository: RepoRef
    public var dataBranch: String
    public var connectorSecrets: [String: String]
    public var openRouterKey: String
    public var runID: Int?
    public var handoverAfter: TimeInterval

    public init(jobID: UUID, targetRepository: RepoRef, workspace: URL, trustedRunnerDirectory: URL? = nil, ipaChecker: Data? = nil, targetToken: String, dataToken: String, dataRepository: RepoRef, dataBranch: String = "main", connectorSecrets: [String: String] = [:], openRouterKey: String, runID: Int? = nil, handoverAfter: TimeInterval = 5.5 * 60 * 60) {
        self.jobID = jobID; self.targetRepository = targetRepository; self.workspace = workspace
        let runnerDirectory = trustedRunnerDirectory ?? workspace.deletingLastPathComponent().appendingPathComponent("maipag-trusted-runner", isDirectory: true)
        self.trustedRunnerDirectory = runnerDirectory
        self.ipaChecker = ipaChecker ?? ((try? Data(contentsOf: CloudToolAssembly.ipaCheckerURL(in: runnerDirectory))) ?? Data())
        self.targetToken = targetToken; self.dataToken = dataToken; self.dataRepository = dataRepository; self.dataBranch = dataBranch
        self.connectorSecrets = connectorSecrets; self.openRouterKey = openRouterKey; self.runID = runID
        self.handoverAfter = handoverAfter
    }
}

public enum CloudRunnerError: Error, Sendable, Equatable, LocalizedError {
    case jobNotFound
    case wrongRepository
    case missingRequest
    case commandFailed
    case noDifferentModel
    case checksFailed
    case handoverRequired
    case missingWorkflowIdentity

    public var errorDescription: String? {
        switch self {
        case .jobNotFound: return "The saved job could not be found."
        case .wrongRepository: return "The job's repository details did not match."
        case .missingRequest: return "The job was missing its request."
        case .commandFailed: return "A command or GitHub step failed. Open the run for its details."
        case .noDifferentModel: return "A genuinely different second AI was not available."
        case .checksFailed: return "The repository's automatic checks still failed after repairs."
        case .handoverRequired: return "The job needed a fresh runner but could not hand over."
        case .missingWorkflowIdentity: return "The job was missing its private saving details."
        }
    }
}

private struct StaticTokenProvider: GitHubTokenProvider {
    var token: String
    func installationToken() async throws -> String { token }
    func userToken() async throws -> String { token }
}

/// Reads and writes one opaque job file in the owner's private MAIPA-G-data repo.
public actor RemoteJobStore {
    private let github: GitHubClient
    private let repo: RepoRef
    private let branch: String

    public init(github: GitHubClient, repo: RepoRef, branch: String = "main") {
        self.github = github; self.repo = repo; self.branch = branch
    }

    public func load(_ id: UUID) async throws -> JobRecord {
        let path = "jobs/\(id.uuidString.lowercased()).json"
        do {
            let data = try await github.fileContents(repo, path: path, ref: branch)
            return try JSONCoding.decoder().decode(JobRecord.self, from: data)
        } catch let error as GitHubAPIError where error.isNotFound {
            throw CloudRunnerError.jobNotFound
        }
    }

    public func save(_ job: JobRecord) async throws {
        let path = "jobs/\(job.id.uuidString.lowercased()).json"
        let safeJob = try SensitiveDataRedactor().redactCodable(job)
        let data = try JSONCoding.encoder(pretty: true).encode(safeJob)
        for attempt in 1...4 {
            guard let head = try await github.branchHead(repo, branch: branch) else { throw CloudRunnerError.jobNotFound }
            do {
                let blob = try await github.createBlob(repo, contents: data)
                let tree = try await github.createTree(repo, base: try await github.commitTree(repo, commit: head), changes: [.init(path: path, blobSHA: blob)])
                let commit = try await github.createCommit(repo, message: "Checkpoint Autonomous job", tree: tree, parents: [head])
                try await github.updateBranch(repo, branch: branch, to: commit)
                return
            } catch let error as GitHubAPIError where error.status == 422 && attempt < 4 {
                continue
            }
        }
    }
}

private actor RemoteWorkflowCheckpointSink {
    private var job: JobRecord
    private let store: RemoteJobStore
    private let workspace: URL
    private let definition: WorkflowDefinition

    init(job: JobRecord, store: RemoteJobStore, workspace: URL, definition: WorkflowDefinition) {
        self.job = job
        self.store = store
        self.workspace = workspace
        self.definition = definition
    }

    func save(_ checkpoint: WorkflowCheckpoint) async throws {
        var object = job.state.objectValue ?? [:]
        object["workflowCheckpoint"] = (try? JSONCoding.encoder().encode(checkpoint)).flatMap(JSONValue.parse)
        object["workspacePatch"] = try await workspacePatch()
        job.state = .object(object)
        job.cumulativeCost = checkpoint.cumulativeCost
        job.steps = workflowSteps(checkpoint)
        job.status = checkpoint.isCancelled ? .stopped : (checkpoint.pendingQuestion == nil ? .running : .needsAnswer)
        job.updatedAt = Date()
        try await store.save(job)
    }

    func current() -> JobRecord { job }

    private func workflowSteps(_ checkpoint: WorkflowCheckpoint) -> [JobStepRecord] {
        definition.flattenedNodes.enumerated().map { index, node in
            let prior = index < job.steps.count ? job.steps[index] : JobStepRecord(title: node.title)
            let status: JobStepRecord.Status
            switch checkpoint.statuses[node.id] {
            case .running: status = .running
            case .waiting: status = .waiting
            case .completed: status = .done
            case .failed: status = .failed
            case .cancelled: status = .stopped
            default: status = .pending
            }
            let detail = checkpoint.outputs.last(where: { $0.nodeID == node.id })?.text
            return JobStepRecord(
                id: prior.id,
                title: node.title,
                detail: detail.map { String($0.prefix(500)) },
                status: status,
                startedAt: status == .pending ? nil : (prior.startedAt ?? checkpoint.updatedAt),
                finishedAt: [.done, .failed, .stopped].contains(status) ? (prior.finishedAt ?? checkpoint.updatedAt) : nil
            )
        }
    }

    private func workspacePatch() async throws -> JSONValue? {
        let add = try await BoundedProcess.run(executable: "/usr/bin/git", arguments: ["add", "-A"], directory: workspace, timeout: 120)
        guard add.exitCode == 0 else { throw CloudRunnerError.commandFailed }
        do {
            let diff = try await BoundedProcess.run(executable: "/usr/bin/git", arguments: ["diff", "--cached", "--binary", "--full-index"], directory: workspace, timeout: 120, outputLimit: 90_000_000)
            guard diff.exitCode == 0 else { throw CloudRunnerError.commandFailed }
            let reset = try await BoundedProcess.run(executable: "/usr/bin/git", arguments: ["reset"], directory: workspace, timeout: 120)
            guard reset.exitCode == 0 else { throw CloudRunnerError.commandFailed }
            return diff.stdout.isEmpty ? nil : .string(diff.stdout)
        } catch {
            _ = try? await BoundedProcess.run(executable: "/usr/bin/git", arguments: ["reset"], directory: workspace, timeout: 120)
            throw error
        }
    }
}

/// Shared Linux execution engine. It checkpoints at every AgentLoop milestone and hands a job to
/// a fresh workflow run before GitHub's hosted-runner limit.
public struct CloudRunner: Sendable {
    private let configuration: CloudRunnerConfiguration
    private let transport: any HTTPTransport
    private let logger: RedactingLogger

    public init(configuration: CloudRunnerConfiguration, transport: any HTTPTransport = URLSessionTransport()) {
        self.configuration = configuration
        self.transport = transport
        logger = RedactingLogger(secrets: [configuration.targetToken, configuration.dataToken, configuration.openRouterKey] + Array(configuration.connectorSecrets.values))
    }

    public func run() async throws {
        let targetGitHub = GitHubClient(transport: transport, tokens: StaticTokenProvider(token: configuration.targetToken))
        let dataGitHub = GitHubClient(transport: transport, tokens: StaticTokenProvider(token: configuration.dataToken))
        let github = targetGitHub
        let store = RemoteJobStore(github: dataGitHub, repo: configuration.dataRepository, branch: configuration.dataBranch)
        var job = try await store.load(configuration.jobID)
        guard job.targetRepo == configuration.targetRepository else { throw CloudRunnerError.wrongRepository }
        guard job.dataRepo == nil || job.dataRepo == configuration.dataRepository else { throw CloudRunnerError.wrongRepository }
        guard job.dataBranch == configuration.dataBranch else { throw CloudRunnerError.wrongRepository }
        guard job.status != .stopped && job.status != .done else { return }

        let startedAt = Date()
        job.status = .running
        job.workflowRunID = configuration.runID
        job.workflowRunURL = configuration.runID.map { "https://github.com/\(configuration.targetRepository.fullName)/actions/runs/\($0)" }
        job.logsURL = job.workflowRunURL
        job.updatedAt = Date()
        try await store.save(job)
        logger.progress("MAIPA-G Autonomous started job \(job.id.uuidString).")

        do {
            let workBranch = try await prepareRepository(for: &job)
            try await store.save(job)
            let toolResults = CloudToolResults()
            let writeRules = try await localWriteRules(for: job)
            if job.state["previewBuild"]?.boolValue == true {
                try await runPreviewBuild(job: &job, branch: workBranch, store: store)
                return
            }
            if let encoded = job.state["workflowDefinition"],
               let definition = try? decode(WorkflowDefinition.self, from: encoded) {
                try await runWorkflow(definition, job: &job, branch: workBranch, store: store, github: github, toolResults: toolResults, startedAt: startedAt)
                return
            }
            var chat = try chatForJob(job)
            applySavedAnswers(job, to: &chat)

            let authorization = ChangeAuthorization(request: chat.firstUserText ?? job.title)
            var tools: [any AgentTool] = [ProcessTool(directory: configuration.workspace, authorization: authorization, rules: writeRules)]
            tools.append(contentsOf: CloudToolAssembly.make(
                github: github, repo: configuration.targetRepository, ref: workBranch,
                workspace: configuration.workspace,
                ipaChecker: configuration.ipaChecker,
                defaultBranch: job.defaultBranch ?? "main", directSave: job.directSave,
                buildExplicitlyRequested: job.state["buildExplicitlyRequested"]?.boolValue == true,
                results: toolResults,
                logger: logger
            ))
            tools.append(contentsOf: try await stdioTools(for: job))
            if let values = job.state["mcpServers"]?.arrayValue {
                for value in values {
                    if let server = try? decode(StdioMCPServer.self, from: value) {
                        tools.append(StdioMCPTool(server: server, directory: configuration.workspace))
                    }
                }
            }
            let route = ModelRouter.route(
                choice: .auto,
                difficulty: .hard,
                thinking: .medium,
                account: AccountState(isFreeTier: false),
                catalogue: [:]
            )
            let input = AgentTurnInput(
                chat: chat,
                route: route,
                systemPrompt: cloudPrompt(repo: configuration.targetRepository, branch: workBranch, rules: writeRules),
                tools: tools,
                spendLimit: job.state["spendLimit"]?.doubleValue,
                requiresInitialSpendApproval: !route.isFree
            )
            let environment = AgentEnvironment(
                openRouter: OpenRouterClient(transport: transport, apiKey: configuration.openRouterKey),
                freeRoute: { ModelRouter.route(choice: .free, difficulty: .hard, thinking: .medium, account: AccountState(), catalogue: [:]) },
                onOutOfCredits: {}
            )
            let run = AgentLoop.start(input, environment: environment)
            var shouldHandOver = false
            for await event in run.events {
                guard case .updated(let turn, let milestone) = event else { continue }
                replaceLastTurn(turn, in: &chat)
                guard milestone else { continue }
                try await captureWorkspace(in: &job)
                update(&job, from: chat, turn: turn)
                try await store.save(job)
                if Date().timeIntervalSince(startedAt) >= configuration.handoverAfter, turn.status == .running {
                    shouldHandOver = true
                    run.cancel()
                }
            }

            if shouldHandOver {
                job.status = .handingOver
                job.handoverGeneration += 1
                job.updatedAt = Date()
                try await store.save(job)
                try await Self.dispatchHandover(job, github: github, repo: configuration.targetRepository)
                logger.progress("Checkpoint saved. A fresh runner will continue the job.")
                return
            }

            guard let turn = chat.lastAssistantTurn else { throw CloudRunnerError.missingRequest }
            update(&job, from: chat, turn: turn)
            switch turn.status {
            case .waitingForUser:
                job.status = turn.spendCheck == nil ? .needsAnswer : .needsApproval
            case .done:
                job.result = try await finishRepository(job: job, branch: workBranch, github: github, toolResults: toolResults, chat: chat)
                job.cumulativeCost += await toolResults.additionalCost
                var state = job.state.objectValue ?? [:]
                state["workspacePatch"] = nil
                job.state = .object(state)
                job.status = .done
            case .stopped:
                job.status = .stopped
            case .failed:
                job.status = .failed
            case .running:
                job.status = .queued
            }
            job.updatedAt = Date()
            try await store.save(job)
            logger.progress("MAIPA-G Autonomous checkpointed \(job.status.rawValue).")
        } catch {
            job.status = .failed
            let description = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            let reason = logger.redact(description)
            job.result = JobResult(summary: "The job stopped safely: \(reason)")
            job.updatedAt = Date()
            try? await store.save(job)
            logger.progress("MAIPA-G Autonomous stopped safely with an error.")
            throw error
        }
    }

    private func runWorkflow(
        _ definition: WorkflowDefinition,
        job: inout JobRecord,
        branch: String,
        store: RemoteJobStore,
        github: GitHubClient,
        toolResults: CloudToolResults,
        startedAt: Date
    ) async throws {
        let savedCheckpoint: WorkflowCheckpoint? = job.state["workflowCheckpoint"].flatMap { try? decode(WorkflowCheckpoint.self, from: $0) }
        let sink = RemoteWorkflowCheckpointSink(job: job, store: store, workspace: configuration.workspace, definition: definition)
        let request = job.state["request"]?.stringValue ?? savedCheckpoint?.request ?? job.title
        let authorization = workflowAuthorization(job: job, request: request)
        let writeRules = try await localWriteRules(for: job)
        var tools: [any AgentTool] = [WorkspaceInspectTool(directory: configuration.workspace), ProcessTool(directory: configuration.workspace, authorization: authorization, rules: writeRules)]
        tools.append(contentsOf: CloudToolAssembly.make(
            github: github, repo: configuration.targetRepository, ref: branch,
            workspace: configuration.workspace,
            ipaChecker: configuration.ipaChecker,
            defaultBranch: job.defaultBranch ?? "main", directSave: job.directSave,
            buildExplicitlyRequested: workflowBuildAuthorized(job: job),
            results: toolResults,
            logger: logger
        ))
        tools.append(contentsOf: try await stdioTools(for: job))
        if let values = job.state["mcpServers"]?.arrayValue {
            for value in values where (try? decode(StdioMCPServer.self, from: value)) != nil {
                if let server = try? decode(StdioMCPServer.self, from: value) { tools.append(StdioMCPTool(server: server, directory: configuration.workspace)) }
            }
        }
        var definitions = BuiltInAgents.all
        if let values = job.state["customAgents"]?.arrayValue {
            definitions += values.compactMap { try? decode(CustomAgentRecord.self, from: $0) }.map(\.definition)
        }
        let repoContext = SystemPrompt.RepoContext(
            ref: configuration.targetRepository,
            branch: branch,
            commit: job.state["targetCommit"]?.stringValue ?? "unknown",
            isPrivate: true,
            summary: nil,
            ruleDocuments: writeRules.documents
        )
        let openRouter = OpenRouterClient(transport: transport, apiKey: configuration.openRouterKey)
        let catalogue = Dictionary(uniqueKeysWithValues: ((try? await openRouter.models()) ?? []).map { ($0.id, $0) })
        let accountState = (try? await openRouter.keyInfo()).map { AccountState(isFreeTier: $0.isFreeTier) } ?? AccountState()
        let environment = AgentEnvironment(
            openRouter: openRouter,
            freeRoute: { ModelRouter.route(choice: .free, difficulty: .hard, thinking: .medium, account: AccountState(), catalogue: catalogue) },
            onOutOfCredits: {}
        )
        let workflowTools = tools
        let spendLimit = job.state["spendLimit"]?.doubleValue
        let runner: AgentExecutor.Runner = { invocation in
            var chat: Chat
            if let value = invocation.resumeState,
               let saved = try? decode(Chat.self, from: value) {
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
                let prompt = [invocation.definition.prompt(task: invocation.task), invocation.context].filter { !$0.isEmpty }.joined(separator: "\n\nContext:\n")
                chat.messages = [.user(prompt), ChatMessage(body: .assistant(AssistantTurn()))]
            }
            let route: Route
            if invocation.definition.modelPolicy == .differentFromPrimary {
                guard let distinct = ModelRouter.distinctRoute(avoiding: invocation.avoidModel, difficulty: invocation.definition.difficulty, thinking: .medium, account: accountState, catalogue: catalogue) else {
                    throw CloudRunnerError.noDifferentModel
                }
                route = distinct
            } else {
                route = ModelRouter.route(choice: .auto, difficulty: invocation.definition.difficulty, thinking: .medium, account: accountState, catalogue: catalogue)
            }
            let input = AgentTurnInput(
                chat: chat, route: route,
                systemPrompt: SystemPrompt.make(userLogin: nil, repo: repoContext, agent: invocation.definition, workflowContext: invocation.context),
                tools: workflowTools + invocation.tools, spendLimit: invocation.spendLimit,
                requiresInitialSpendApproval: !route.isFree, agent: invocation.definition
            )
            var final: AssistantTurn?
            let agentRun = AgentLoop.start(input, environment: environment)
            let remaining = max(0, configuration.handoverAfter - Date().timeIntervalSince(startedAt))
            let deadline = Task {
                if remaining > 0 { try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000)) }
                if !Task.isCancelled { agentRun.cancel() }
            }
            for await event in agentRun.events {
                if case .updated(let turn, _) = event { final = turn }
            }
            deadline.cancel()
            if Date().timeIntervalSince(startedAt) >= configuration.handoverAfter { throw CloudRunnerError.handoverRequired }
            guard let turn = final, turn.status != .failed else { throw CloudRunnerError.commandFailed }
            let output = turn.steps.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n\n")
            let pending = turn.pendingQuestions?.questions.questions.first.map { AgentExecutionQuestion(text: $0.text, options: $0.options) }
            return AgentExecutionResult(
                output: output, model: turn.steps.last?.model,
                goalOutcome: AgentGoalOutcome.parse(output), cost: turn.usage.cost ?? 0,
                needsSpendingApproval: turn.spendCheck != nil, pendingQuestion: pending,
                resumeState: pending != nil || turn.spendCheck != nil ? encode(chat) : nil
            )
        }
        let engine = WorkflowEngine(definition: definition, checkpoint: savedCheckpoint, agents: definitions, spendLimit: spendLimit, runner: runner) { checkpoint in
            try await sink.save(checkpoint)
        }
        if let pending = savedCheckpoint?.pendingQuestion,
           let answer = job.questions.first(where: { $0.text == pending.text })?.answer {
            try await engine.answer(nodeID: pending.nodeID, answer: answer)
        }
        let outcome = await engine.run(request: job.state["request"]?.stringValue)
        job = await sink.current()
        if Date().timeIntervalSince(startedAt) >= configuration.handoverAfter {
            job.status = .handingOver
            job.handoverGeneration += 1
            job.updatedAt = Date()
            try await store.save(job)
            try await Self.dispatchHandover(job, github: github, repo: configuration.targetRepository)
            logger.progress("Workflow checkpoint saved. A fresh runner will continue the job.")
            return
        }
        switch outcome {
        case .completed(let checkpoint):
            var result = try await finishRepository(job: job, branch: branch, github: github, toolResults: toolResults, summaryOverride: checkpoint.outputs.last?.text)
            if definition.id.hasPrefix("spec-task:") {
                result.verificationPassed = checkpoint.outputs.last.map { Self.hasPassingMarker($0.text) } ?? false
            }
            job.result = result
            job.cumulativeCost += await toolResults.additionalCost
            job.status = .done
            job.questions = []
        case .waiting(_, let question):
            job.status = .needsAnswer
            let old = job.questions.first { $0.text == question.text }
            job.questions = [JobQuestion(id: old?.id ?? UUID(), text: question.text, options: question.options, answer: old?.answer, isApproval: ["Allow", "Start build", "Keep going", "Continue"].contains(question.options.first ?? ""))]
        case .cancelled:
            job.status = .stopped
        case .failed(_, let message):
            job.status = .failed
            job.result = JobResult(summary: message)
        }
        job.updatedAt = Date()
        try await store.save(job)
    }

    private func chatForJob(_ job: JobRecord) throws -> Chat {
        if let value = job.state["chat"], let chat = try? decode(Chat.self, from: value) { return chat }
        guard let request = job.state["request"]?.stringValue, !request.isEmpty else { throw CloudRunnerError.missingRequest }
        var chat = Chat(title: job.title)
        chat.messages = [.user(request), ChatMessage(body: .assistant(AssistantTurn()))]
        return chat
    }

    private func workflowBuildAuthorized(job: JobRecord) -> Bool {
        if job.state["buildExplicitlyRequested"]?.boolValue == true { return true }
        return job.questions.contains { question in
            question.text.lowercased().contains("start this github actions workflow") && question.answer == question.options.first
        }
    }

    private func workflowAuthorization(job: JobRecord, request: String) -> ChangeAuthorization {
        ChangeAuthorization(request: request)
    }

    private func applySavedAnswers(_ job: JobRecord, to chat: inout Chat) {
        guard var turn = chat.lastAssistantTurn else { return }
        let questions = job.questions
        var answers = questions.filter { !$0.text.contains("This job has cost") }.compactMap(\.answer).makeIterator()
        for stepIndex in turn.steps.indices {
            for callIndex in turn.steps[stepIndex].toolCalls.indices where turn.steps[stepIndex].toolCalls[callIndex].status == .waitingForUser {
                if let answer = answers.next() {
                    turn.steps[stepIndex].toolCalls[callIndex].questions?.answers = [answer]
                }
            }
        }
        if let spent = turn.spendCheck,
           questions.first(where: { $0.text.contains("This job has cost") })?.answer == "Keep going" {
            turn.approvedSpendUpTo = spent + max(job.state["spendLimit"]?.doubleValue ?? 1, 0.01)
            turn.spendCheck = nil
        }
        replaceLastTurn(turn, in: &chat)
    }

    private func update(_ job: inout JobRecord, from chat: Chat, turn: AssistantTurn) {
        var state = job.state.objectValue ?? [:]
        state["chat"] = encode(chat)
        state["request"] = nil
        job.state = .object(state)
        job.cumulativeCost = turn.usage.cost ?? job.cumulativeCost
        job.steps = turn.steps.enumerated().map { index, step in
            let calls = step.toolCalls.map(\.summary)
            let detail = calls.isEmpty ? (step.text.isEmpty ? nil : String(step.text.prefix(160))) : calls.joined(separator: " · ")
            let status: JobStepRecord.Status
            if step.finishedAt == nil { status = .running }
            else if step.toolCalls.contains(where: { $0.status == .failed }) { status = .failed }
            else { status = .done }
            return JobStepRecord(id: step.id, title: "Step \(index + 1)", detail: detail, status: status, startedAt: step.startedAt, finishedAt: step.finishedAt)
        }
        let old = job.questions
        var next: [JobQuestion] = []
        for step in turn.steps {
            for call in step.toolCalls where call.status == .waitingForUser {
                for question in call.questions?.questions ?? [] {
                    let previous = old.first { $0.text == question.text }
                    next.append(JobQuestion(
                        id: previous?.id ?? UUID(), text: question.text, options: question.options,
                        answer: previous?.answer,
                        isApproval: question.options.contains("Allow") || question.options.contains("Yes")
                    ))
                }
            }
        }
        if let spent = turn.spendCheck {
            let text = "This job has cost $\(String(format: "%.2f", spent)). Keep going?"
            let previous = old.first { $0.text == text }
            next.append(JobQuestion(id: previous?.id ?? UUID(), text: text, options: ["Keep going", "Stop"], answer: previous?.answer, isApproval: true))
        }
        job.questions = next
        job.updatedAt = Date()
    }

    private func prepareRepository(for job: inout JobRecord) async throws -> String {
        let selected = job.targetRef ?? job.defaultBranch ?? "main"
        let defaultBranch = job.defaultBranch ?? "main"
        let effectiveRules = try await localWriteRules(for: job)
        let savesDirectly = effectiveRules.directSave
        job.directSave = savesDirectly
        var state = job.state.objectValue ?? [:]
        state["effectiveDirectSave"] = .bool(savesDirectly)
        state["repoRuleReason"] = effectiveRules.reason.map(JSONValue.string)
        let existing = state["workBranch"]?.stringValue
        let branch = existing ?? (effectiveRules.directSave
            ? selected
            : (selected != defaultBranch
                ? selected
                : "maipa-g/\(Self.slug(job.title))-\(job.id.uuidString.lowercased().prefix(8))"))
        let botName = state["botName"]?.stringValue ?? "maipa-g[bot]"
        let botSlug = botName.replacingOccurrences(of: "[bot]", with: "")
        try await git(["config", "user.name", botName])
        try await git(["config", "user.email", "\(botSlug)[bot]@users.noreply.github.com"])
        let checkedOut = try await git(["rev-parse", "HEAD"]).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if let expected = state["targetCommit"]?.stringValue, expected != checkedOut, existing == nil {
            throw CloudRunnerError.commandFailed
        }
        try await git(["checkout", "-B", branch, checkedOut])
        state["trustedHead"] = .string(checkedOut)
        if let patch = state["workspacePatch"]?.stringValue, !patch.isEmpty {
            let result = try await BoundedProcess.run(
                executable: "/usr/bin/git", arguments: ["apply", "--whitespace=nowarn", "-"],
                directory: configuration.workspace, stdin: Data(patch.utf8), timeout: 120
            )
            guard result.exitCode == 0 else { throw CloudRunnerError.commandFailed }
        }
        state["workBranch"] = .string(branch)
        job.state = .object(state)
        return branch
    }

    /// Saves the complete staged/unstaged/untracked workspace as a binary Git patch in the
    /// private job record. This avoids publishing half-finished direct-save work while still
    /// allowing a fresh runner to restore every completed step.
    private func captureWorkspace(in job: inout JobRecord) async throws {
        try await git(["add", "-A"])
        let patch = try await git(["diff", "--cached", "--binary", "--full-index"], allowFailure: true).stdout
        try await git(["reset"])
        var state = job.state.objectValue ?? [:]
        state["workspacePatch"] = patch.isEmpty ? nil : .string(patch)
        job.state = .object(state)
    }

    private func finishRepository(job: JobRecord, branch: String, github: GitHubClient, toolResults: CloudToolResults, chat: Chat? = nil, summaryOverride: String? = nil) async throws -> JobResult {
        let effectiveRules = try await localWriteRules(for: job)
        let selected = job.targetRef ?? job.defaultBranch ?? "main"
        let destination = effectiveRules.directSave ? selected : branch
        let baseRef = effectiveRules.directSave ? selected : (job.defaultBranch ?? "main")
        let publisher = GitHubWorkspacePublisher(github: github, repo: configuration.targetRepository, workspace: configuration.workspace)
        guard try await publisher.hasChanges() else {
            var summary = summaryOverride ?? chat?.lastAssistantTurn?.steps.last(where: { !$0.text.isEmpty })?.text ?? "Finished the requested work."
            summary += "\n\nNo files needed changing."
            return JobResult(summary: summary, commit: job.state["targetCommit"]?.stringValue)
        }
        let commit = try await publisher.publish(branch: destination, baseRef: baseRef, message: job.title)

        var pullRequest = await toolResults.pullRequest
        if pullRequest == nil, !effectiveRules.directSave, branch != (job.defaultBranch ?? "main") {
            pullRequest = try await github.openOrReusePullRequest(
                configuration.targetRepository,
                title: job.title,
                body: "Changes made and checked by MAIPA-G Autonomous.",
                head: branch,
                base: job.defaultBranch ?? "main"
            )
        }
        let verified = try await verifyChecksAndRepair(job: job, branch: destination, baseRef: baseRef, initialCommit: commit, github: github, toolResults: toolResults)
        let verifiedCommit = verified.commit
        var buildURL = verified.report.runs.last?.htmlURL
        var artifactURL: String?
        let successfulRuns = verified.report.runs.filter { ["success", "neutral", "skipped"].contains($0.conclusion ?? "") }
        for run in successfulRuns {
            let artifacts = (try? await github.artifacts(configuration.targetRepository, runID: run.id)) ?? []
            if let artifact = artifacts.first(where: { !$0.expired }) {
                artifactURL = artifact.archiveDownloadURL
                break
            }
        }
        if buildURL == nil { buildURL = successfulRuns.last?.htmlURL }
        var summary = summaryOverride ?? chat?.lastAssistantTurn?.steps.last(where: { !$0.text.isEmpty })?.text ?? "Finished the requested work."
        switch verified.report.discovery {
        case .observed: summary += "\n\nGitHub's automatic checks passed."
        case .confirmedNoChecks: summary += "\n\nThis repo has no automatic checks for this change."
        case .timedOut: summary += "\n\nGitHub didn't start any automatic checks for this change, so nothing was checked automatically."
        }
        return JobResult(summary: summary, pullRequest: pullRequest, commit: verifiedCommit, buildURL: buildURL, artifactURL: artifactURL)
    }

    private func verifyChecksAndRepair(
        job: JobRecord,
        branch: String,
        baseRef: String,
        initialCommit: String,
        github: GitHubClient,
        toolResults: CloudToolResults
    ) async throws -> (commit: String, report: GitHubRunWatchResult) {
        var commit = initialCommit
        var repairContext = ""
        let watcher = GitHubRunWatcher(github: github)
        for attempt in 0...2 {
            let report = try await watcher.wait(repo: configuration.targetRepository, commit: commit, branch: branch, excludingRunID: configuration.runID, redacting: logger)
            if report.succeeded { return (commit, report) }
            // No check ever started (for example, the repo's builds only run on main or on certain
            // folders). There is nothing to repair; the result says plainly that nothing was checked.
            if report.discovery == .timedOut { return (commit, report) }
            guard attempt < 2 else { throw CloudRunnerError.checksFailed }
            repairContext = [repairContext, report.failedLogs].filter { !$0.isEmpty }.joined(separator: "\n\n")
            let rules = try await localWriteRules(for: job)
            let tools: [any AgentTool] = [WorkspaceInspectTool(directory: configuration.workspace), ProcessTool(directory: configuration.workspace, authorization: ChangeAuthorization(request: job.state["request"]?.stringValue ?? job.title), rules: rules)]
                + CloudToolAssembly.make(
                    github: github, repo: configuration.targetRepository, ref: branch, workspace: configuration.workspace,
                    ipaChecker: configuration.ipaChecker,
                    defaultBranch: job.defaultBranch ?? "main", directSave: rules.directSave,
                    buildExplicitlyRequested: false, results: toolResults, logger: logger
                )
            let repairCost = await toolResults.additionalCost
            let remaining = job.state["spendLimit"]?.doubleValue.map { max(0.000_001, $0 - job.cumulativeCost - repairCost) }
            let coder = try await executeCloudAgent(
                BuiltInAgents.named("coder")!,
                task: "Repair the automatic checks for commit \(commit). Inspect the actual redacted logs, make only the necessary fix, and run the affected local checks. Do not commit or push.",
                context: repairContext,
                tools: tools,
                rules: rules,
                spendLimit: remaining,
                avoidModel: nil
            )
            await toolResults.add(cost: coder.cost)
            let checker = try await executeCloudAgent(
                BuiltInAgents.named("code-checker")!,
                task: "Check the repair against the failed logs and current workspace. End with a standalone GOAL_MET line only if the repair is complete and local checks support it; otherwise end with GOAL_NOT_MET.",
                context: coder.output,
                tools: tools,
                rules: rules,
                spendLimit: remaining.map { max(0.000_001, $0 - coder.cost) },
                avoidModel: coder.model
            )
            await toolResults.add(cost: checker.cost)
            repairContext += "\n\nCoder:\n\(coder.output)\n\nChecker:\n\(checker.output)"
            guard checker.goalOutcome == .met else { continue }
            commit = try await GitHubWorkspacePublisher(github: github, repo: configuration.targetRepository, workspace: configuration.workspace)
                .publish(branch: branch, baseRef: baseRef, expectedRemoteHead: commit, message: "Fix automatic checks")
        }
        throw CloudRunnerError.checksFailed
    }

    private func executeCloudAgent(
        _ definition: AgentDefinition,
        task: String,
        context: String,
        tools: [any AgentTool],
        rules: RepoWriteRules,
        spendLimit: Double?,
        avoidModel: String?
    ) async throws -> AgentExecutionResult {
        let openRouter = OpenRouterClient(transport: transport, apiKey: configuration.openRouterKey)
        let models = (try? await openRouter.models()) ?? []
        let catalogue = Dictionary(uniqueKeysWithValues: models.map { ($0.id, $0) })
        let account = (try? await openRouter.keyInfo()).map { AccountState(isFreeTier: $0.isFreeTier) } ?? AccountState()
        let route: Route
        if definition.modelPolicy == .differentFromPrimary {
            guard let selected = ModelRouter.distinctRoute(avoiding: avoidModel, difficulty: definition.difficulty, thinking: .medium, account: account, catalogue: catalogue) else { throw CloudRunnerError.noDifferentModel }
            route = selected
        } else {
            route = ModelRouter.route(choice: .auto, difficulty: definition.difficulty, thinking: .medium, account: account, catalogue: catalogue)
        }
        var chat = Chat(title: definition.name)
        chat.messages = [.user([definition.prompt(task: task), context].filter { !$0.isEmpty }.joined(separator: "\n\nContext:\n")), ChatMessage(body: .assistant(AssistantTurn()))]
        let repo = SystemPrompt.RepoContext(ref: configuration.targetRepository, branch: "checked workspace", commit: try await git(["rev-parse", "HEAD"]).stdout.trimmingCharacters(in: .whitespacesAndNewlines), isPrivate: true, summary: nil, ruleDocuments: rules.documents)
        let input = AgentTurnInput(chat: chat, route: route, systemPrompt: SystemPrompt.make(userLogin: nil, repo: repo, agent: definition, workflowContext: context), tools: tools, spendLimit: spendLimit, requiresInitialSpendApproval: !route.isFree, agent: definition)
        let environment = AgentEnvironment(openRouter: openRouter, freeRoute: { ModelRouter.route(choice: .free, difficulty: definition.difficulty, thinking: .medium, account: AccountState(), catalogue: catalogue) }, onOutOfCredits: {})
        var final: AssistantTurn?
        for await event in AgentLoop.run(input, environment: environment) { if case .updated(let turn, _) = event { final = turn } }
        guard let turn = final, turn.status == .done else { throw CloudRunnerError.commandFailed }
        let output = turn.steps.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n\n")
        return AgentExecutionResult(output: output, model: turn.steps.last?.model, goalOutcome: AgentGoalOutcome.parse(output), cost: turn.usage.cost ?? 0)
    }

    private func localWriteRules(for job: JobRecord) async throws -> RepoWriteRules {
        let directSave = job.directSave || job.state["effectiveDirectSave"]?.boolValue == true
        let directReason = job.state["repoRuleReason"]?.stringValue
        var documents = Self.ruleDocuments(in: configuration.workspace)
        documents.sort {
            let leftDepth = $0.0.split(separator: "/").count, rightDepth = $1.0.split(separator: "/").count
            return leftDepth == rightDepth ? $0.0 < $1.0 : leftDepth < rightDepth
        }
        var resolved = RepoWriteRules.resolve(documents: documents, directSaveSetting: directSave)
        if directSave, let directReason { resolved.reason = directReason }
        return resolved
    }

    /// The repo's own rules files (AGENTS.md, .kiro/steering, owner-rules.md). Synchronous on
    /// purpose: Apple's folder enumerator can't be looped over inside async code.
    static func ruleDocuments(in workspace: URL) -> [(String, String)] {
        guard let values = FileManager.default.enumerator(at: workspace, includingPropertiesForKeys: [.isRegularFileKey], options: []) else { return [] }
        var documents: [(String, String)] = []
        while let url = values.nextObject() as? URL {
            let relative = String(url.path.dropFirst(workspace.path.count + 1))
            let name = url.lastPathComponent
            if name == ".git" || name == "node_modules" || name == ".build" {
                values.skipDescendants()
                continue
            }
            let lower = relative.lowercased()
            guard lower == "agents.md" || lower.hasSuffix("/agents.md") || lower.contains(".kiro/steering/") || lower.hasSuffix("owner-rules.md") else { continue }
            guard documents.count < 100, let data = try? Data(contentsOf: url), data.count <= 1_000_000, let text = String(data: data, encoding: .utf8) else { continue }
            documents.append((relative, text))
        }
        return documents
    }

    private func runPreviewBuild(job: inout JobRecord, branch: String, store: RemoteJobStore) async throws {
        guard let command = job.state["previewBuildCommand"]?.stringValue,
              let expectedCommit = job.state["previewCommit"]?.stringValue else { throw CloudRunnerError.missingRequest }
        let actualCommit = try await git(["rev-parse", "HEAD"]).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard actualCommit == expectedCommit else { throw CloudRunnerError.commandFailed }
        // A project inside a folder (web/, site/…) installs, builds and outputs in that folder.
        let rootPath = job.state["previewRoot"]?.stringValue ?? ""
        guard rootPath.isEmpty || SnapshotStore.isSafeRelativePath(rootPath) else { throw CloudRunnerError.missingRequest }
        let project = rootPath.isEmpty ? configuration.workspace : configuration.workspace.appendingPathComponent(rootPath, isDirectory: true)
        let install = Self.previewInstallCommand(in: project)
        let result = try await BoundedProcess.run(executable: "/bin/bash", arguments: ["-lc", "\(install) && \(command)"], directory: project, timeout: 900, outputLimit: 80_000)
        guard result.exitCode == 0 else { throw CloudRunnerError.commandFailed }
        let outputs = job.state["previewOutputDirectories"]?.arrayValue?.compactMap(\.stringValue) ?? ["dist", "build", "out", ".output/public"]
        guard let source = outputs.map({ project.appendingPathComponent($0, isDirectory: true) }).first(where: { FileManager.default.fileExists(atPath: $0.appendingPathComponent("index.html").path) }) else {
            throw WebPreviewError.missingResource("built index.html")
        }
        let destination = configuration.workspace.appendingPathComponent(".maipag-preview-artifact", isDirectory: true)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: source, to: destination)
        let tracked = try await git(["diff", "--name-only", "HEAD", "--", "."], allowFailure: true).stdout
        guard tracked.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CloudRunnerError.commandFailed }
        job.status = .done
        job.result = JobResult(summary: "Built the preview artifact from \(expectedCommit.prefix(7)).", commit: expectedCommit, buildURL: job.workflowRunURL)
        job.steps = [JobStepRecord(title: "Build preview", detail: "Artifact ready for upload", status: .done, startedAt: job.createdAt, finishedAt: Date())]
        job.updatedAt = Date()
        try await store.save(job)
        logger.progress("Preview build finished and is ready for artifact upload.")
    }

    static func previewInstallCommand(in project: URL) -> String {
        if FileManager.default.fileExists(atPath: project.appendingPathComponent("pnpm-lock.yaml").path) { return "pnpm install --frozen-lockfile" }
        if FileManager.default.fileExists(atPath: project.appendingPathComponent("yarn.lock").path) { return "yarn install --immutable" }
        if FileManager.default.fileExists(atPath: project.appendingPathComponent("package-lock.json").path) { return "npm ci" }
        return "npm install"
    }

    private func stdioTools(for job: JobRecord) async throws -> [any AgentTool] {
        #if os(Linux)
        var tools: [any AgentTool] = []
        for value in job.state["stdioConnectors"]?.arrayValue ?? [] {
            guard let configuration = try? decode(ConnectorConfiguration.self, from: value), configuration.kind == .stdio else { continue }
            let connector = AutonomousStdioConnector(configuration: configuration, workspace: self.configuration.workspace)
            let prefix = configuration.id.uuidString.lowercased() + "."
            let secrets = self.configuration.connectorSecrets.reduce(into: [String: String]()) { values, item in
                if item.key.hasPrefix(prefix) { values[String(item.key.dropFirst(prefix.count))] = item.value }
            }
            let definitions = try await connector.connect(environment: secrets)
            tools.append(contentsOf: definitions
                .filter { !configuration.disabledTools.contains($0.originalName) }
                .map { AutonomousMCPTool(definition: $0, connector: connector) })
        }
        return tools
        #else
        return []
        #endif
    }

    @discardableResult
    private func git(_ arguments: [String], allowFailure: Bool = false) async throws -> ProcessResult {
        let result = try await BoundedProcess.run(executable: "/usr/bin/git", arguments: arguments, directory: configuration.workspace, timeout: 600)
        if result.exitCode != 0 && !allowFailure { throw CloudRunnerError.commandFailed }
        return result
    }

    private func cloudPrompt(repo: RepoRef, branch: String, rules: RepoWriteRules) -> String {
        """
        You are MAIPA-G Autonomous working in \(repo.fullName) on \(branch). Use run_shell for real repository work. Inspect before editing, follow the repository's rules, make the requested change completely, and run its existing checks. Do not commit or push; the runner brokers those operations after policy validation. Ask before deleting files or changing build setup unless the request already clearly authorizes that exact operation and path. Never print credentials or secret environment values. Start a workflow build only when the person's request explicitly asks for one; inspecting automatic checks is allowed.

        Applicable repository instructions:
        \(rules.promptText)
        """
    }

    private func encode<T: Encodable>(_ value: T) -> JSONValue {
        (try? JSONCoding.encoder().encode(value)).flatMap(JSONValue.parse) ?? .null
    }

    private func decode<T: Decodable>(_ type: T.Type, from value: JSONValue) throws -> T {
        try JSONCoding.decoder().decode(type, from: JSONCoding.encoder().encode(value))
    }

    private func replaceLastTurn(_ turn: AssistantTurn, in chat: inout Chat) {
        guard let index = chat.messages.indices.last, chat.messages[index].assistantTurn != nil else { return }
        chat.messages[index].assistantTurn = turn
        chat.updatedAt = Date()
    }

    public static func dispatchHandover(_ job: JobRecord, github: GitHubClient, repo: RepoRef) async throws {
        guard let inputs = job.autonomousWorkflowInputs else { throw CloudRunnerError.missingWorkflowIdentity }
        try await github.dispatchWorkflow(
            repo,
            workflow: "maipa-g.yml",
            ref: job.defaultBranch ?? "main",
            inputs: inputs
        )
    }

    private static func hasPassingMarker(_ text: String) -> Bool {
        text.components(separatedBy: .newlines).contains { $0.trimmingCharacters(in: .whitespacesAndNewlines) == "GOAL_MET" }
    }

    private static func slug(_ value: String) -> String {
        let words = value.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }.split(separator: "-")
        return String(words.prefix(6).joined(separator: "-")).prefix(48).description.ifEmpty("job")
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}
