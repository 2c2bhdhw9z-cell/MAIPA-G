import AgentCore
import Foundation
import Observation

/// One open chat: its messages, what's typed in its box, and the AI working on it. A chat keeps
/// going while the user looks at other chats.
@MainActor
@Observable
final class ChatSession: Identifiable {
    let id: UUID
    private(set) var chat: Chat
    var draft = "" { didSet { scheduleDraftSave() } }
    var draftAttachments: [AttachmentReference] = [] { didSet { scheduleDraftSave() } }
    var webEnabled = true
    var autonomous = false
    private(set) var isRunning = false
    private(set) var mergeCheckStatus: String?
    private(set) var mergeWarning: String?

    @ObservationIgnored weak var app: AppModel?
    @ObservationIgnored private var run: AgentRun?
    @ObservationIgnored private var workspace: RepoWorkspace?
    @ObservationIgnored private var changeWorkspace: ChangeWorkspace?
    /// What MAIPA-G last put on the chat computer, so unchanged staged edits aren't sent again.
    @ObservationIgnored private var lastComputerSync: String?
    @ObservationIgnored private var lastComputerCheck: Date?
    @ObservationIgnored private var changeSession: ChangeSession?
    @ObservationIgnored private var pendingTurn: AssistantTurn?
    @ObservationIgnored private var flushScheduled = false
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var draftSaveTask: Task<Void, Never>?
    @ObservationIgnored private var lastSaved = Date()

    init(chat: Chat, app: AppModel?, draft: ComposerDraft? = nil) {
        self.id = chat.id
        self.chat = chat
        self.app = app
        self.draft = draft?.text ?? ""
        self.draftAttachments = draft?.attachments ?? []
    }

    private func scheduleDraftSave() {
        guard !PreviewScenes.isActive, let store = app?.library.store else { return }
        draftSaveTask?.cancel()
        let value = ComposerDraft(text: draft, attachments: draftAttachments)
        let path = ComposerDraft.path(for: id.uuidString.lowercased())
        draftSaveTask = Task {
            do { try await Task.sleep(nanoseconds: 400_000_000) } catch { return }
            do {
                if value.isEmpty { try await store.deleteItem(at: path) }
                else { try await store.saveDocument(value, at: path) }
            } catch {
                _ = app?.report(error, area: "draft", operation: "save chat draft", path: path)
            }
        }
    }

    var lastTurn: AssistantTurn? { chat.lastAssistantTurn }
    var contextModelID: String? {
        chat.messages.reversed().compactMap(\.assistantTurn).flatMap { $0.steps.reversed() }.compactMap(\.model).first
    }
    var contextUsedTokens: Int {
        // The latest request's prompt already includes the conversation and every returned tool
        // result. Add its answer to show what the next request will need to carry forward.
        if let usage = chat.messages.reversed().compactMap(\.assistantTurn).flatMap({ $0.steps.reversed() }).compactMap(\.usage).first {
            return max(0, usage.promptTokens + usage.completionTokens)
        }
        // Before OpenRouter has reported usage, give a conservative plain-text estimate rather than
        // showing a made-up exact number.
        let characters = chat.messages.reduce(0) { total, message in
            switch message.body {
            case .user(let user): return total + user.text.count
            case .assistant(let turn):
                return total + turn.steps.reduce(0) { partial, step in
                    partial + step.text.count + step.reasoning.count + step.toolCalls.reduce(0) { $0 + $1.arguments.count + ($1.result?.count ?? 0) }
                }
            }
        }
        return max(0, characters / 4)
    }
    var isWaitingForAnswers: Bool { lastTurn?.pendingQuestions != nil }
    var isWaitingOnSpend: Bool { lastTurn?.status == .waitingForUser && lastTurn?.spendCheck != nil }

    // MARK: What the user does

    func send(_ text: String, attachments: [AttachmentReference] = []) {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (!message.isEmpty || !attachments.isEmpty), !isRunning else { return }
        if attachments.isEmpty, let repo = chat.repo, let app {
            if autonomous {
                autonomous = false
                Task { await app.jobs.start(request: message, repo: repo) }
                return
            }
            if let workflow = app.jobs.routedWorkflow(request: message, repo: repo) {
                Task { await app.jobs.start(request: message, repo: repo, workflow: workflow) }
                return
            }
        }
        settleWaitingTurn()
        chat.messages.append(.user(message, attachments: attachments))
        chat.messages.append(ChatMessage(body: .assistant(AssistantTurn())))
        if chat.title.isEmpty { chat.title = Self.provisionalTitle(message.isEmpty ? attachments.first?.name ?? "Attachment" : message) }
        touch()
        start()
    }

    func resumeInterruptedTurn() {
        guard !isRunning, lastTurn?.status == .running else { return }
        start()
    }

    func stagedDiff() async -> String {
        await changeWorkspace?.stagedDiff() ?? "No staged changes in this turn."
    }

    func branchDiff() async -> String {
        guard let app, let github = app.github.client, let repo = chat.repo else { return "Connect GitHub to load the branch diff." }
        let branch = (chat.saveReceipts ?? []).last { $0.pullRequest != nil && $0.resolution == nil }?.branch ?? repo.branch
        do {
            let comparison = try await github.compare(repo.ref, base: repo.defaultBranch, head: branch)
            if comparison.files.isEmpty { return "No branch changes." }
            return String(comparison.files.map { file in
                "--- \(file.status): \(file.path)\n" + (file.patch ?? "GitHub did not provide a text patch for this file.")
            }.joined(separator: "\n\n").prefix(200_000))
        } catch {
            return ErrorExplainer.explain(error).message
        }
    }

    /// Answers the AI's numbered questions and lets it carry on.
    func answer(_ answers: [String]) {
        guard !isRunning, var turn = lastTurn, let pending = turn.pendingQuestions else { return }
        turn.steps[pending.stepIndex].toolCalls[pending.callIndex].questions?.answers = answers
        replaceLastTurn(turn)
        touch()
        start()
    }

    /// "Keep going" after the stop-and-ask amount: allows the same amount again.
    func approveMoreSpending() {
        guard !isRunning, var turn = lastTurn, let spent = turn.spendCheck, let app else { return }
        turn.approvedSpendUpTo = spent + max(app.settings.spendLimit, 0.01)
        turn.spendCheck = nil
        replaceLastTurn(turn)
        touch()
        start()
    }

    func stop() {
        guard isRunning else {
            settleWaitingTurn()
            return
        }
        run?.cancel()
    }

    /// Runs any saved answer again, rewinding messages after it but preserving the preceding user
    /// message and all tool results that belong to earlier turns.
    func retryAnswer(_ messageID: UUID) {
        guard !isRunning, let index = chat.messages.firstIndex(where: { $0.id == messageID }),
              chat.messages[index].assistantTurn != nil else { return }
        chat.messages.removeSubrange(index...)
        chat.messages.append(ChatMessage(body: .assistant(AssistantTurn())))
        chat.compactedSummary = nil
        chat.compactedThroughMessageID = nil
        touch()
        start()
    }

    func editAndResend(_ messageID: UUID, text: String) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isRunning, !clean.isEmpty,
              let index = chat.messages.firstIndex(where: { $0.id == messageID }),
              case .user(let original) = chat.messages[index].body else { return }
        chat.messages.removeSubrange(index...)
        chat.messages.append(ChatMessage(body: .user(UserMessage(text: clean, attachments: original.attachments))))
        chat.messages.append(ChatMessage(body: .assistant(AssistantTurn())))
        chat.compactedSummary = nil
        chat.compactedThroughMessageID = nil
        touch()
        start()
    }

    func compact() {
        guard !isRunning, chat.messages.count > 4 else { return }
        let throughIndex = chat.messages.count - 3
        let older = chat.messages[...throughIndex]
        var lines: [String] = []
        for message in older {
            switch message.body {
            case .user(let user):
                if !user.text.isEmpty { lines.append("Person: " + String(user.text.prefix(1_500))) }
            case .assistant(let turn):
                let text = turn.steps.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n")
                if !text.isEmpty { lines.append("MAIPA-G: " + String(text.prefix(2_500))) }
            }
            if lines.joined(separator: "\n").count >= 18_000 { break }
        }
        guard !lines.isEmpty else { return }
        chat.compactedSummary = String(lines.joined(separator: "\n\n").prefix(20_000))
        chat.compactedThroughMessageID = chat.messages[throughIndex].id
        appendNotice("Compacted older messages for future AI requests. The full chat remains visible.")
        touch()
    }

    /// Runs the last message again, after a failure.
    func retry() {
        guard !isRunning, let last = chat.messages.last, last.assistantTurn != nil else { return }
        chat.messages[chat.messages.count - 1] = ChatMessage(body: .assistant(AssistantTurn()))
        touch()
        start()
    }

    /// For "out of credit": switch this chat to the free AIs and try again.
    func switchToFreeAIs() {
        chat.model = .free
        retry()
    }

    func setModel(_ choice: ModelChoice) {
        chat.model = choice
        if let levels = app?.openRouter.thinkingLevels(for: choice), !levels.isEmpty, let nearest = chat.thinking.nearest(in: levels) {
            chat.thinking = nearest
        }
        touch()
    }

    func setThinking(_ level: ThinkingLevel) {
        chat.thinking = level
        touch()
    }

    func setRepo(_ repo: ChatRepo?) {
        chat.repo = repo
        workspace = nil
        changeWorkspace = nil
        changeSession = nil
        touch()
    }

    func setGroup(_ id: UUID?) {
        chat.groupID = id
        touch()
    }

    func toggleStar(_ messageID: UUID) {
        guard let index = chat.messages.firstIndex(where: { $0.id == messageID }), let app else { return }
        let message = chat.messages[index]
        let text: String
        switch message.body {
        case .user(let user): text = user.text
        case .assistant(let turn): text = turn.steps.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n\n")
        }
        Task {
            let memoryID = await app.memories.toggleStar(messageID: message.id, text: text, currentMemoryID: message.starredMemoryID)
            chat.messages[index].starredMemoryID = memoryID
            touch()
        }
    }

    func rename(_ title: String) {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        chat.title = String(clean.prefix(80))
        chat.titleIsCustom = true
        touch()
    }

    func addLastSave(force: Bool = false) async {
        guard let app, let github = app.github.client, var receipts = chat.saveReceipts,
              let index = receipts.indices.last, let pull = receipts[index].pullRequest, receipts[index].resolution == nil else { return }
        do {
            let result = try await GitHubRunWatcher(github: github, maximumPolls: 1, discoveryPolls: 1, sleeper: {}).wait(
                repo: receipts[index].repo,
                commit: receipts[index].savedCommit,
                branch: receipts[index].branch,
                redacting: RedactingLogger()
            )
            if result.succeeded {
                mergeCheckStatus = result.discovery == .confirmedNoChecks ? "No automatic checks" : "Checks passed"
            } else {
                let failed = result.runs.filter { $0.conclusion != nil && !["success", "neutral", "skipped"].contains($0.conclusion!) }.map(\.name)
                    + result.checks.filter { $0.conclusion != nil && !["success", "neutral", "skipped"].contains($0.conclusion!) }.map(\.name)
                    + result.statuses.filter { $0.state != "success" }.map(\.context)
                mergeCheckStatus = failed.isEmpty ? "Checks are pending or did not start" : "Failing: " + failed.joined(separator: ", ")
                if !force {
                    mergeWarning = "\(mergeCheckStatus ?? "Checks did not pass"). Add pull request #\(pull.number) anyway?"
                    return
                }
            }
            try await GitHubChangeService(github: github).addIt(receipts[index])
            receipts[index].resolution = "added"
            chat.saveReceipts = receipts
            mergeWarning = nil
            appendNotice("Added the pull request and removed its side branch.")
        } catch {
            let explanation = ErrorExplainer.explain(error)
            if let api = error as? GitHubAPIError, api.status == 409 || api.status == 422 {
                appendNotice("GitHub could not merge pull request #\(pull.number): \(explanation.cause) Open the pull request, resolve the named conflicting files, then tap Add it again. \(pull.htmlURL)")
            } else {
                appendNotice("Couldn’t add pull request #\(pull.number): \(explanation.message)")
            }
        }
    }

    func cancelMergeWarning() { mergeWarning = nil }

    func throwAwayLastSave() async {
        guard let app, let github = app.github.client, var receipts = chat.saveReceipts,
              let index = receipts.indices.last, receipts[index].pullRequest != nil, receipts[index].resolution == nil else { return }
        do {
            try await GitHubChangeService(github: github).throwAway(receipts[index])
            receipts[index].resolution = "discarded"
            chat.saveReceipts = receipts
            appendNotice("Closed the pull request and removed its side branch.")
        } catch { appendNotice("Couldn't throw it away: \(error)") }
    }

    func undoLastSave() async {
        guard let app, let github = app.github.client, var receipts = chat.saveReceipts,
              let index = receipts.lastIndex(where: { $0.undoneAt == nil }) else { return }
        do {
            _ = try await GitHubChangeService(github: github).undo(receipts[index])
            receipts[index].undoneAt = Date()
            chat.saveReceipts = receipts
            appendNotice("Undid MAIPA-G's last save.")
        } catch { appendNotice("Undo stopped safely: \(error)") }
    }

    private func appendNotice(_ text: String) {
        guard var turn = lastTurn else { return }
        turn.notices.append(text)
        replaceLastTurn(turn)
        touch()
    }

    // MARK: Running

    private func start() {
        app?.notifications.requestIfNeeded(enabled: app?.settings.notificationsOn == true)
        isRunning = true
        let grace = BackgroundGrace(name: "MAIPA-G reply") { [weak self] in self?.stop() }
        Task { [weak self] in
            await self?.runTurn()
            grace.end()
        }
    }

    private func runTurn() async {
        defer {
            isRunning = false
            run = nil
            saveSoon(immediately: true)
            app?.turnFinished(in: self)
        }
        guard let app else { return }
        guard let apiKey = app.openRouter.apiKey else {
            fail(.signInNeeded, "Sign in with OpenRouter first, so MAIPA-G can talk to the AIs.")
            return
        }

        let lastMessage = chat.messages.last { $0.userText != nil }?.userText ?? ""
        let changeAuthorization = ChangeAuthorization(request: lastMessage)
        let allAttachments = chat.messages.flatMap { message -> [AttachmentReference] in
            if case .user(let user) = message.body { return user.attachments }
            return []
        }
        var attachmentData: [UUID: Data] = [:]
        for attachment in allAttachments where attachment.kind == .image || attachment.kind == .pdf {
            attachmentData[attachment.id] = try? await app.attachmentStore.data(for: attachment)
        }
        var tools: [any AgentTool] = webEnabled ? [WebSearchTool(transport: app.transport), ReadWebPageTool(transport: app.transport)] : []
        tools.append(contentsOf: app.connectors.agentTools())
        tools.append(AddMemoryTool(store: app.memories.store))
        tools.append(EditMemoryTool(store: app.memories.store))
        if let github = app.github.client {
            tools.append(CreateRepositoryTool(github: github))
            tools.append(ReadOtherRepositoryFileTool(github: github, repositories: app.github.repos))
            tools.append(LiveStatusTool { [weak app] in
                await MainActor.run { app?.liveStatusText() ?? "MAIPA-G is no longer open." }
            })
        }
        if !allAttachments.filter({ $0.kind == .text }).isEmpty {
            tools.append(ReadAttachmentTool(attachments: allAttachments, store: app.attachmentStore))
        }
        var repoContext: SystemPrompt.RepoContext?
        var repoHooks: [RepoHook] = []
        var hookProblems: [String] = []
        if let repo = chat.repo {
            guard let github = app.github.client else {
                fail(.signInNeeded, "Connect GitHub so MAIPA-G can read \(repo.ref.fullName).")
                return
            }
            do {
                let activeReceipt = (chat.saveReceipts ?? []).last { $0.repo == repo.ref && $0.pullRequest != nil && $0.resolution == nil }
                let workingBranch = activeReceipt?.branch ?? repo.branch
                let workingRepo = ChatRepo(ref: repo.ref, branch: workingBranch, defaultBranch: repo.defaultBranch, isPrivate: repo.isPrivate)
                let commit = try await github.resolveCommit(repo.ref, ref: workingBranch)
                let workspace = workspaceFor(repo: workingRepo, commit: commit, github: github, store: app.snapshots)
                await workspace.prefetch()
                let changes: ChangeWorkspace
                if let existing = changeWorkspace, existing.base.commit == commit {
                    changes = existing
                } else {
                    changes = ChangeWorkspace(base: workspace)
                    changeWorkspace = changes
                }
                let service = GitHubChangeService(github: github)
                let rules = await service.resolveRules(in: workspace, directSaveSetting: app.settings.savesDirectly(to: repo.ref))
                let loadedHooks = await RepoHooks.load(from: workspace)
                repoHooks = loadedHooks.hooks
                hookProblems = loadedHooks.problems
                let saves = changeSession ?? ChangeSession(receipts: chat.saveReceipts ?? [])
                changeSession = saves
                let repoTools: [any AgentTool] = [
                    ListFilesTool(workspace: workspace), SearchCodeTool(workspace: workspace), ReadFileTool(workspace: workspace), ReadRepoFileTool(github: github), LoadRepoRulesTool(documents: rules.documents),
                    CreateFileTool(workspace: changes, authorization: changeAuthorization, rules: rules), EditFileTool(workspace: changes, authorization: changeAuthorization, rules: rules), DeleteFileTool(workspace: changes, authorization: changeAuthorization, rules: rules),
                    SaveChangesTool(workspace: changes, service: service, session: saves, selectedBranch: workingBranch, defaultBranch: repo.defaultBranch, rules: rules),
                ]
                tools.append(contentsOf: repoTools)
                repoContext = SystemPrompt.RepoContext(
                    ref: repo.ref,
                    branch: workingBranch,
                    commit: commit,
                    isPrivate: repo.isPrivate,
                    summary: app.github.repo(named: repo.ref.fullName)?.summary,
                    ruleDocuments: rules.documents
                )
            } catch {
                fail(.other, "Couldn't open \(repo.ref.fullName) on GitHub. \(app.github.describe(error))")
                return
            }
        }
        let computerNote = await prepareComputer(app: app, repo: repoContext)
        var canSyncStaged = false
        if let repoContext, let workspace = changeWorkspace, let control = app.connectors.computerControl(), control.commandTool != nil, app.openRouter.supportsTools(chat.model) {
            tools.append(SyncStagedToComputerTool(
                control: control, workspace: workspace,
                homePath: "repos/\(repoContext.ref.owner)/\(repoContext.ref.name)",
                cloneURL: repoContext.isPrivate ? nil : "https://github.com/\(repoContext.ref.owner)/\(repoContext.ref.name).git",
                commit: repoContext.commit
            ))
            canSyncStaged = true
        }
        // Hooks from the repo's .kiro/hooks run after the tools they listen to. Command hooks run
        // on the chat computer, in the repo's copy, after the staged files are put there.
        var hookRunner: HookedTool.CommandRunner?
        if let repoContext, let workspace = changeWorkspace, let control = app.connectors.computerControl(), control.commandTool != nil {
            let homePath = "repos/\(repoContext.ref.owner)/\(repoContext.ref.name)"
            let cloneURL: String? = repoContext.isPrivate ? nil : "https://github.com/\(repoContext.ref.owner)/\(repoContext.ref.name).git"
            let commit = repoContext.commit
            hookRunner = { command in
                _ = try await control.syncStagedChanges(homePath: homePath, cloneURL: cloneURL, commit: commit, changes: await workspace.stagedChanges())
                return try await control.run("cd \"$HOME/\(homePath)\" && \(command)")
            }
        }
        if let control = app.connectors.computerControl(), control.commandTool != nil, app.openRouter.supportsTools(chat.model) {
            tools.append(ComputerTaskTool(control: control, homePath: repoContext.map { "repos/\($0.ref.owner)/\($0.ref.name)" }))
        }
        tools = HookedTool.wrap(tools, hooks: repoHooks, runCommand: hookRunner)
        for problem in hookProblems {
            _ = app.report(RepoHookProblem(message: problem), area: "hooks", operation: "read repo hooks")
        }
        var computer = await computerContext(app: app, repo: repoContext, stagedPatch: await changeWorkspace?.stagedDiff())
        computer?.appNote = computerNote
        computer?.canSyncStaged = canSyncStaged

        let hasRepo = chat.repo != nil
        var difficulty = TaskDifficulty.estimate(lastMessage, hasRepo: hasRepo)
        if chat.model == .auto, app.openRouter.accountState.paidAllowed(),
           let judged = await OnDeviceAI.difficulty(of: lastMessage, hasRepo: hasRepo) {
            difficulty = judged
        }
        let catalogue = app.openRouter.modelsByID
        if case .model(let modelID) = chat.model,
           let model = catalogue[modelID],
           (allAttachments.contains(where: { $0.kind == .image }) && !model.acceptsImages ||
            allAttachments.contains(where: { $0.kind == .pdf }) && !model.acceptsFiles) {
            fail(.other, "This AI can't read pictures or PDFs. Pick Auto or an AI that accepts them.")
            return
        }
        let thinking = chat.thinking
        let judgedDifficulty = difficulty
        let hasImageInput = allAttachments.contains { $0.kind == .image }
        let route = ModelRouter.route(choice: chat.model, difficulty: judgedDifficulty, thinking: thinking, account: app.openRouter.accountState, catalogue: catalogue, requiresImageInput: hasImageInput)
        if let imageModel = app.openRouter.models.first(where: \.generatesImages) {
            tools.append(GenerateImageTool(client: app.openRouter.client, store: app.attachmentStore, model: imageModel.id, maySpend: !imageModel.isFree))
        }
        let fallbackModels = app.openRouter.models.filter { model in
            model.id != route.model && model.isChatModel
                && (!hasRepo || model.supportsTools)
                && (!hasImageInput || model.acceptsImages)
                && (!route.isFree || model.isFree)
        }.prefix(3).map(\.id)
        let input = AgentTurnInput(
            chat: chat,
            route: route,
            systemPrompt: SystemPrompt.make(
                userLogin: app.github.login,
                repo: repoContext,
                computer: computer,
                memories: chat.memoryContext,
                connectedRepositories: app.github.repos.map(\.fullName)
            ),
            tools: tools,
            allowTools: app.openRouter.supportsTools(chat.model),
            spendLimit: app.settings.spendLimitOn ? app.settings.spendLimit : nil,
            attachmentData: attachmentData,
            serverTools: webEnabled && app.openRouter.accountState.paidAllowed() ? OpenRouterWebTools.paid : [],
            fallbackModels: fallbackModels,
            requiresInitialSpendApproval: !route.isFree
        )
        let account = app.openRouter
        var environment = AgentEnvironment(
            openRouter: OpenRouterClient(transport: app.transport, apiKey: apiKey),
            freeRoute: {
                ModelRouter.route(choice: .free, difficulty: judgedDifficulty, thinking: thinking, account: AccountState(), catalogue: catalogue, requiresImageInput: hasImageInput)
            },
            onOutOfCredits: { await account.markOutOfCredits() }
        )
        environment.onModelRestricted = { model in await account.markRestricted(model) }

        let run = AgentLoop.start(input, environment: environment)
        self.run = run
        for await event in run.events {
            guard case .updated(let turn, let milestone) = event else { continue }
            receive(turn, milestone: milestone)
        }
        if lastTurn?.steps.flatMap(\.toolCalls).contains(where: { $0.name == "add_memory" || $0.name == "edit_memory" }) == true {
            await app.memories.load()
            app.sync.request()
        }
        if let saves = changeSession {
            let receipts = await saves.receipts()
            var existing = Set((chat.saveReceipts ?? []).map(\.id))
            for receipt in receipts where existing.insert(receipt.id).inserted {
                chat.saveReceipts = (chat.saveReceipts ?? []) + [receipt]
            }
        }
        flush()
        if var turn = lastTurn, turn.status == .running {
            turn.status = .stopped
            replaceLastTurn(turn)
        }
        chat.updatedAt = Date()
        await nameChatIfNeeded()
    }

    /// Streamed updates are drawn at most every 33 ms; finished steps and tools at once.
    private func receive(_ turn: AssistantTurn, milestone: Bool) {
        if milestone {
            pendingTurn = nil
            replaceLastTurn(turn)
            chat.updatedAt = Date()
            saveSoon()
            return
        }
        pendingTurn = turn
        guard !flushScheduled else { return }
        flushScheduled = true
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 33_000_000)
            self?.flush()
        }
    }

    private func flush() {
        flushScheduled = false
        if let turn = pendingTurn {
            pendingTurn = nil
            replaceLastTurn(turn)
        }
    }

    private func replaceLastTurn(_ turn: AssistantTurn) {
        guard let index = chat.messages.indices.last, chat.messages[index].assistantTurn != nil else { return }
        chat.messages[index].assistantTurn = turn
    }

    private func fail(_ kind: TurnFailure.Kind, _ message: String) {
        guard var turn = lastTurn else { return }
        turn.status = .failed
        turn.failure = TurnFailure(kind: kind, message: message)
        replaceLastTurn(turn)
    }

    /// A turn left waiting (questions, or the spend check) is closed off when the user moves on.
    private func settleWaitingTurn() {
        guard var turn = lastTurn, turn.status == .waitingForUser else { return }
        if turn.spendCheck != nil {
            turn.status = .stopped
            turn.spendCheck = nil
        } else {
            turn.status = .done
        }
        replaceLastTurn(turn)
    }

    private func workspaceFor(repo: ChatRepo, commit: String, github: GitHubClient, store: SnapshotStore) -> RepoWorkspace {
        if let workspace, workspace.repo == repo.ref, workspace.commit == commit, workspace.branch == repo.branch {
            return workspace
        }
        let fresh = RepoWorkspace(repo: repo.ref, branch: repo.branch, commit: commit, github: github, store: store)
        workspace = fresh
        return fresh
    }

    // MARK: The chat's computer

    /// The connector that gives chats a Linux computer, as chosen in Settings: none when it's off,
    /// the chosen one, or for Automatic the first one on sprites.dev. Only a connector that is
    /// connected right now counts, as only those give the AI their tools.
    private func computerConnector(_ app: AppModel) -> ConnectorConfiguration? {
        app.connectors.computerConnector()
    }

    /// Before the AI starts, MAIPA-G's own code checks the machine with a real command, creates
    /// it again when it is missing, takes a provider checkpoint when the service has one, and puts
    /// the phone-staged changes onto its copy of the repo. Returns what the AI is told.
    private func prepareComputer(app: AppModel, repo: SystemPrompt.RepoContext?) async -> String? {
        guard app.openRouter.supportsTools(chat.model), let control = app.connectors.computerControl(), control.commandTool != nil else { return nil }
        var notes: [String] = []
        if lastComputerCheck.map({ Date().timeIntervalSince($0) > 600 }) ?? true {
            do {
                switch try await control.ensureMachine(allowCreate: true) {
                case .healthy(let output):
                    notes.append("MAIPA-G checked `\(control.machine)` with a real command before this message; it answered.")
                    switch ComputerControl.toolState(output) {
                    case .ready:
                        if let failed = ComputerControl.failedTools(output) {
                            notes.append("MAIPA-G's tool setup finished on this machine, but these didn't install: \(failed). If a task needs one of them, say it is missing.")
                        }
                    case .installing:
                        notes.append("MAIPA-G's checked tool set is still installing on this machine in the background. Use the tools that are there; if one is missing, say which and that it is still installing.")
                    case .missing:
                        let revision = Bundle.main.object(forInfoDictionaryKey: "MAIPAGReviewedRevision") as? String ?? ""
                        do { notes.append(try await control.startVerifiedSetup(revision: revision)) }
                        catch { notes.append("MAIPA-G couldn't start installing its tools: \(ErrorExplainer.explain(error).message)") }
                    }
                case .recreated:
                    notes.append("`\(control.machine)` was missing, so MAIPA-G's own code created it again with that exact name and checked it with a real command.")
                    let revision = Bundle.main.object(forInfoDictionaryKey: "MAIPAGReviewedRevision") as? String ?? ""
                    do { notes.append(try await control.startVerifiedSetup(revision: revision)) }
                    catch { notes.append("MAIPA-G couldn't start its verified tool setup: \(ErrorExplainer.explain(error).message)") }
                }
                lastComputerCheck = Date()
            } catch {
                lastComputerCheck = nil
                return "MAIPA-G's own check of `\(control.machine)` failed before this message: \(ErrorExplainer.explain(error).message) Tell the person; don't pretend commands ran."
            }
        }
        if let repo, let workspace = changeWorkspace {
            let changes = await workspace.stagedChanges()
            let fingerprint = changes.map { "\($0.path):\($0.hashValue)" }.joined(separator: "|") + repo.commit
            if !changes.isEmpty, fingerprint != lastComputerSync {
                if control.checkpointTool != nil {
                    do {
                        _ = try await control.createCheckpoint(comment: "MAIPA-G before syncing staged changes for \(repo.ref.fullName)")
                        notes.append("MAIPA-G took a provider checkpoint of `\(control.machine)` before changing its copy of the repo.")
                    } catch {
                        notes.append("A provider checkpoint couldn't be taken: \(ErrorExplainer.explain(error).message)")
                    }
                } else {
                    notes.append("This computer service has no checkpoint tool, so no checkpoint was taken.")
                }
                do {
                    let status = try await control.syncStagedChanges(homePath: "repos/\(repo.ref.owner)/\(repo.ref.name)", cloneURL: repo.isPrivate ? nil : "https://github.com/\(repo.ref.owner)/\(repo.ref.name).git", commit: repo.commit, changes: changes)
                    lastComputerSync = fingerprint
                    notes.append("MAIPA-G's own code already made ~/repos/\(repo.ref.owner)/\(repo.ref.name) match the phone-staged changes. git status:\n\(status.isEmpty ? "clean" : status)")
                } catch {
                    notes.append("MAIPA-G couldn't put the staged changes on the computer: \(ErrorExplainer.explain(error).message)")
                }
            }
        }
        return notes.joined(separator: "\n")
    }

    /// What the AI is told about this chat's computer, or nil when the chat has none.
    private func computerContext(app: AppModel, repo: SystemPrompt.RepoContext?, stagedPatch: String? = nil) async -> SystemPrompt.ComputerContext? {
        guard app.openRouter.supportsTools(chat.model), let connector = computerConnector(app) else { return nil }
        let machine = app.settings.chatComputerMachineName
        guard let repo else { return SystemPrompt.ComputerContext(service: connector.displayName, machine: machine, approximateHourlyCost: app.settings.chatComputerHourlyCost) }
        let owner = repo.ref.owner
        let name = repo.ref.name
        let cloneURL = "https://github.com/\(owner)/\(name).git"
        return SystemPrompt.ComputerContext(
            service: connector.displayName,
            machine: machine,
            repoFullName: repo.ref.fullName,
            cloneURL: cloneURL,
            branch: repo.branch,
            commit: repo.commit,
            repoPath: "$HOME/repos/\(owner)/\(name)",
            stagedPatch: stagedPatch,
            approximateHourlyCost: app.settings.chatComputerHourlyCost
        )
    }

    // MARK: Titles and saving

    static func provisionalTitle(_ message: String) -> String {
        let line = message.components(separatedBy: .newlines).first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? message
        let clean = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count > 42 else { return clean }
        let cut = clean.prefix(42)
        if let space = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: space) > 20 {
            return String(cut[..<space]) + "…"
        }
        return String(cut) + "…"
    }

    /// After the first reply, asks the iPhone's own AI for a better title.
    private func nameChatIfNeeded() async {
        guard !chat.titleIsCustom,
              chat.messages.filter({ $0.userText != nil }).count == 1,
              let message = chat.firstUserText,
              chat.title == Self.provisionalTitle(message),
              let turn = lastTurn, turn.status == .done
        else { return }
        let reply = turn.steps.last(where: { !$0.text.isEmpty })?.text ?? ""
        if let title = await OnDeviceAI.title(message: message, reply: reply), !chat.titleIsCustom {
            chat.title = title
            saveSoon(immediately: true)
        }
    }

    private func touch() {
        chat.updatedAt = Date()
        saveSoon()
    }

    /// Saves within a second, gathering quick changes into one save, but never leaves more than
    /// three seconds of a long reply unsaved.
    func saveSoon(immediately: Bool = false) {
        saveTask?.cancel()
        let overdue = Date().timeIntervalSince(lastSaved) > 3
        let delay: UInt64 = immediately || overdue ? 0 : 800_000_000
        saveTask = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
            guard !Task.isCancelled, let self, let app = self.app else { return }
            self.lastSaved = Date()
            await app.library.save(self.chat)
        }
    }
}
