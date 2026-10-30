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

    @ObservationIgnored weak var app: AppModel?
    @ObservationIgnored private var run: AgentRun?
    @ObservationIgnored private var workspace: RepoWorkspace?
    @ObservationIgnored private var changeWorkspace: ChangeWorkspace?
    @ObservationIgnored private var changeSession: ChangeSession?
    @ObservationIgnored private var pendingTurn: AssistantTurn?
    @ObservationIgnored private var flushScheduled = false
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var draftSaveTask: Task<Void, Never>?
    @ObservationIgnored private var lastSaved = Date()
    /// The read-only token for cloning this chat's private repo onto its computer.
    @ObservationIgnored private var computerToken: (repo: RepoRef, token: String, expiresAt: Date)?

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
                // The chat itself still remains on the phone; the next edit retries this draft.
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

    func addLastSave() async {
        guard let app, let github = app.github.client, var receipts = chat.saveReceipts,
              let index = receipts.indices.last, receipts[index].pullRequest != nil, receipts[index].resolution == nil else { return }
        do {
            try await GitHubChangeService(github: github).addIt(receipts[index])
            receipts[index].resolution = "added"
            chat.saveReceipts = receipts
            appendNotice("Added the pull request and removed its side branch.")
        } catch { appendNotice("Couldn't add it: \(error)") }
    }

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
        if !allAttachments.filter({ $0.kind == .text }).isEmpty {
            tools.append(ReadAttachmentTool(attachments: allAttachments, store: app.attachmentStore))
        }
        var repoContext: SystemPrompt.RepoContext?
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
                let saves = changeSession ?? ChangeSession(receipts: chat.saveReceipts ?? [])
                changeSession = saves
                let repoTools: [any AgentTool] = [
                    ListFilesTool(workspace: workspace), SearchCodeTool(workspace: workspace), ReadFileTool(workspace: workspace), ReadRepoFileTool(github: github),
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
        let computer = await computerContext(app: app, repo: repoContext)

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
        let input = AgentTurnInput(
            chat: chat,
            route: route,
            systemPrompt: SystemPrompt.make(userLogin: app.github.login, repo: repoContext, computer: computer, memories: chat.memoryContext),
            tools: tools,
            allowTools: app.openRouter.supportsTools(chat.model),
            spendLimit: app.settings.spendLimitOn ? app.settings.spendLimit : nil,
            attachmentData: attachmentData,
            serverTools: webEnabled && app.openRouter.accountState.paidAllowed() ? OpenRouterWebTools.paid : []
        )
        let account = app.openRouter
        let environment = AgentEnvironment(
            openRouter: OpenRouterClient(transport: app.transport, apiKey: apiKey),
            freeRoute: {
                ModelRouter.route(choice: .free, difficulty: judgedDifficulty, thinking: thinking, account: AccountState(), catalogue: catalogue, requiresImageInput: hasImageInput)
            },
            onOutOfCredits: { await account.markOutOfCredits() }
        )

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
        guard !app.settings.chatComputerOff else { return nil }
        let ready = app.connectors.connected.filter { app.connectors.states[$0.id] == .connected }
        if let chosen = app.settings.chatComputerServer {
            return ready.first { $0.serverID == chosen }
        }
        return ready.first { connector in
            guard let host = connector.endpoint?.host?.lowercased() else { return false }
            return host == "sprites.dev" || host.hasSuffix(".sprites.dev")
        }
    }

    /// What the AI is told about this chat's computer, or nil when the chat has none.
    private func computerContext(app: AppModel, repo: SystemPrompt.RepoContext?) async -> SystemPrompt.ComputerContext? {
        guard app.openRouter.supportsTools(chat.model), let connector = computerConnector(app) else { return nil }
        let machine = app.settings.chatComputerMachineName
        guard let repo else { return SystemPrompt.ComputerContext(service: connector.displayName, machine: machine) }
        let owner = repo.ref.owner
        let name = repo.ref.name
        var cloneURL = "https://github.com/\(owner)/\(name).git"
        if repo.isPrivate, let token = await readOnlyCloneToken(for: repo.ref, app: app) {
            cloneURL = "https://x-access-token:\(token)@github.com/\(owner)/\(name).git"
        }
        return SystemPrompt.ComputerContext(
            service: connector.displayName,
            machine: machine,
            repoFullName: repo.ref.fullName,
            cloneURL: cloneURL,
            branch: repo.branch,
            commit: repo.commit,
            repoPath: "$HOME/repos/\(owner)/\(name)"
        )
    }

    /// A token that can only read this chat's private repo, kept until five minutes before it runs
    /// out. Nil when GitHub won't make one; the plain address is used then.
    private func readOnlyCloneToken(for repo: RepoRef, app: AppModel) async -> String? {
        if let cached = computerToken, cached.repo == repo, cached.expiresAt.timeIntervalSinceNow > 5 * 60 {
            return cached.token
        }
        computerToken = nil
        guard let fresh = try? await app.github.readOnlyToken(for: repo) else { return nil }
        computerToken = (repo: repo, token: fresh.token, expiresAt: fresh.expiresAt)
        return fresh.token
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
