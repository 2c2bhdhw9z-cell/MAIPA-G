import Foundation

public struct CloudRunnerConfiguration: Sendable {
    public var jobID: UUID
    public var targetRepository: RepoRef
    public var workspace: URL
    public var githubToken: String
    public var openRouterKey: String
    public var runID: Int?
    public var handoverAfter: TimeInterval

    public init(jobID: UUID, targetRepository: RepoRef, workspace: URL, githubToken: String, openRouterKey: String, runID: Int? = nil, handoverAfter: TimeInterval = 5.5 * 60 * 60) {
        self.jobID = jobID; self.targetRepository = targetRepository; self.workspace = workspace
        self.githubToken = githubToken; self.openRouterKey = openRouterKey; self.runID = runID
        self.handoverAfter = handoverAfter
    }
}

public enum CloudRunnerError: Error, Sendable, Equatable {
    case jobNotFound
    case wrongRepository
    case missingRequest
    case commandFailed
    case handoverRequired
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
        let data = try JSONCoding.encoder(pretty: true).encode(job)
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
        logger = RedactingLogger(secrets: [configuration.githubToken, configuration.openRouterKey])
    }

    public func run() async throws {
        let tokens = StaticTokenProvider(token: configuration.githubToken)
        let github = GitHubClient(transport: transport, tokens: tokens)
        let dataRepo = RepoRef(owner: configuration.targetRepository.owner, name: DataRepoSync.repoName)
        let store = RemoteJobStore(github: github, repo: dataRepo)
        var job = try await store.load(configuration.jobID)
        guard job.targetRepo == configuration.targetRepository else { throw CloudRunnerError.wrongRepository }
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
            if let encoded = job.state["workflowDefinition"],
               let definition = try? decode(WorkflowDefinition.self, from: encoded) {
                try await runWorkflow(definition, job: &job, branch: workBranch, store: store, github: github, startedAt: startedAt)
                return
            }
            var chat = try chatForJob(job)
            applySavedAnswers(job, to: &chat)

            let authorization = ChangeAuthorization(request: chat.firstUserText ?? job.title)
            var tools: [any AgentTool] = [ProcessTool(directory: configuration.workspace, authorization: authorization)]
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
                systemPrompt: cloudPrompt(repo: configuration.targetRepository, branch: workBranch),
                tools: tools,
                spendLimit: job.state["spendLimit"]?.doubleValue
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
                try await github.dispatchWorkflow(
                    configuration.targetRepository,
                    workflow: "maipa-g.yml",
                    ref: job.defaultBranch ?? "main",
                    inputs: ["job_id": job.id.uuidString.lowercased()]
                )
                logger.progress("Checkpoint saved. A fresh runner will continue the job.")
                return
            }

            guard let turn = chat.lastAssistantTurn else { throw CloudRunnerError.missingRequest }
            update(&job, from: chat, turn: turn)
            switch turn.status {
            case .waitingForUser:
                job.status = turn.spendCheck == nil ? .needsAnswer : .needsApproval
            case .done:
                job.result = try await finishRepository(job: job, branch: workBranch, github: github, chat: chat)
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
        startedAt: Date
    ) async throws {
        let savedCheckpoint: WorkflowCheckpoint? = job.state["workflowCheckpoint"].flatMap { try? decode(WorkflowCheckpoint.self, from: $0) }
        let sink = RemoteWorkflowCheckpointSink(job: job, store: store, workspace: configuration.workspace, definition: definition)
        let request = job.state["request"]?.stringValue ?? savedCheckpoint?.request ?? job.title
        let authorization = ChangeAuthorization(request: request)
        var tools: [any AgentTool] = [WorkspaceInspectTool(directory: configuration.workspace), ProcessTool(directory: configuration.workspace, authorization: authorization)]
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
        let environment = AgentEnvironment(
            openRouter: OpenRouterClient(transport: transport, apiKey: configuration.openRouterKey),
            freeRoute: { ModelRouter.route(choice: .free, difficulty: .hard, thinking: .medium, account: AccountState(), catalogue: [:]) },
            onOutOfCredits: {}
        )
        let workflowTools = tools
        let spendLimit = job.state["spendLimit"]?.doubleValue
        let runner: AgentExecutor.Runner = { invocation in
            var chat = Chat(title: invocation.definition.name)
            let prompt = [invocation.definition.prompt(task: invocation.task), invocation.context].filter { !$0.isEmpty }.joined(separator: "\n\nContext:\n")
            chat.messages = [.user(prompt), ChatMessage(body: .assistant(AssistantTurn()))]
            let choice: ModelChoice = invocation.definition.modelPolicy == .differentFromPrimary ? .free : .auto
            let route = ModelRouter.route(choice: choice, difficulty: invocation.definition.difficulty, thinking: .medium, account: AccountState(), catalogue: [:])
            let input = AgentTurnInput(
                chat: chat, route: route,
                systemPrompt: SystemPrompt.make(userLogin: nil, repo: nil, agent: invocation.definition, workflowContext: invocation.context),
                tools: workflowTools, spendLimit: spendLimit, agent: invocation.definition
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
            return AgentExecutionResult(output: output, model: turn.steps.last?.model, goalMet: output.uppercased().contains("GOAL_MET"), cost: turn.usage.cost ?? 0)
        }
        let engine = WorkflowEngine(definition: definition, checkpoint: savedCheckpoint, agents: definitions, runner: runner) { checkpoint in
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
            try await github.dispatchWorkflow(
                configuration.targetRepository,
                workflow: "maipa-g.yml",
                ref: job.defaultBranch ?? "main",
                inputs: ["job_id": job.id.uuidString.lowercased()]
            )
            logger.progress("Workflow checkpoint saved. A fresh runner will continue the job.")
            return
        }
        switch outcome {
        case .completed(let checkpoint):
            job.result = try await finishRepository(job: job, branch: branch, github: github, summaryOverride: checkpoint.outputs.last?.text)
            job.status = .done
            job.questions = []
        case .waiting(_, let question):
            job.status = .needsAnswer
            let old = job.questions.first { $0.text == question.text }
            job.questions = [JobQuestion(id: old?.id ?? UUID(), text: question.text, options: question.options, answer: old?.answer)]
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
        var state = job.state.objectValue ?? [:]
        let existing = state["workBranch"]?.stringValue
        let branch = existing ?? (job.directSave || selected != defaultBranch
            ? selected
            : "maipa-g/\(Self.slug(job.title))-\(job.id.uuidString.lowercased().prefix(8))")
        let botName = state["botName"]?.stringValue ?? "maipa-g[bot]"
        let botSlug = botName.replacingOccurrences(of: "[bot]", with: "")
        try await git(["config", "user.name", botName])
        try await git(["config", "user.email", "\(botSlug)[bot]@users.noreply.github.com"])
        try await git(["fetch", "origin", selected])
        if existing != nil {
            let fetched = try await git(["fetch", "origin", branch], allowFailure: true)
            if fetched.exitCode == 0 {
                try await git(["checkout", "-B", branch, "origin/\(branch)"])
            } else {
                try await git(["checkout", "-B", branch, "origin/\(selected)"])
            }
        } else {
            try await git(["checkout", "-B", branch, "origin/\(selected)"])
        }
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

    private func finishRepository(job: JobRecord, branch: String, github: GitHubClient, chat: Chat? = nil, summaryOverride: String? = nil) async throws -> JobResult {
        let status = try await git(["status", "--porcelain"], allowFailure: true)
        var commit: String?
        if !status.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try await git(["add", "-A"])
            try await git(["commit", "-m", job.title])
            commit = try await git(["rev-parse", "HEAD"]).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        try await git(["push", "origin", "HEAD:refs/heads/\(branch)"])

        var pullRequest: GitHubPullRequest?
        if !job.directSave, branch != (job.defaultBranch ?? "main") {
            pullRequest = try await github.openPullRequest(
                configuration.targetRepository,
                title: job.title,
                body: "Changes made and checked by MAIPA-G Autonomous.",
                head: branch,
                base: job.defaultBranch ?? "main"
            )
        }
        let summary = summaryOverride ?? chat?.lastAssistantTurn?.steps.last(where: { !$0.text.isEmpty })?.text ?? "Finished the requested work."
        return JobResult(summary: summary, pullRequest: pullRequest, commit: commit)
    }

    private func stdioTools(for job: JobRecord) async throws -> [any AgentTool] {
        #if os(Linux)
        var tools: [any AgentTool] = []
        for value in job.state["stdioConnectors"]?.arrayValue ?? [] {
            guard let configuration = try? decode(ConnectorConfiguration.self, from: value), configuration.kind == .stdio else { continue }
            let connector = AutonomousStdioConnector(configuration: configuration)
            let definitions = try await connector.connect()
            tools.append(contentsOf: definitions.map { AutonomousMCPTool(definition: $0, connector: connector) })
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

    private func cloudPrompt(repo: RepoRef, branch: String) -> String {
        """
        You are MAIPA-G Autonomous working in \(repo.fullName) on \(branch). Use run_shell for real repository work. Inspect before editing, follow the repository's rules, make the requested change completely, and run its existing checks. Do not commit or push; the runner does that after you finish. Ask before deleting files or changing build setup unless the request already clearly authorizes it. Never print credentials or secret environment values. Start a workflow build only when the person's request explicitly asks for one; inspecting automatic checks is allowed.
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

    private static func slug(_ value: String) -> String {
        let words = value.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }.split(separator: "-")
        return String(words.prefix(6).joined(separator: "-")).prefix(48).description.ifEmpty("job")
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}
