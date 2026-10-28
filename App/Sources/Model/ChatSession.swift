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
    var draft = ""
    private(set) var isRunning = false

    @ObservationIgnored weak var app: AppModel?
    @ObservationIgnored private var run: AgentRun?
    @ObservationIgnored private var workspace: RepoWorkspace?
    @ObservationIgnored private var pendingTurn: AssistantTurn?
    @ObservationIgnored private var flushScheduled = false
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var lastSaved = Date()

    init(chat: Chat, app: AppModel?) {
        self.id = chat.id
        self.chat = chat
        self.app = app
    }

    var lastTurn: AssistantTurn? { chat.lastAssistantTurn }
    var isWaitingForAnswers: Bool { lastTurn?.pendingQuestions != nil }
    var isWaitingOnSpend: Bool { lastTurn?.status == .waitingForUser && lastTurn?.spendCheck != nil }

    // MARK: What the user does

    func send(_ text: String) {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, !isRunning else { return }
        settleWaitingTurn()
        chat.messages.append(.user(message))
        chat.messages.append(ChatMessage(body: .assistant(AssistantTurn())))
        if chat.title.isEmpty { chat.title = Self.provisionalTitle(message) }
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
        touch()
    }

    func rename(_ title: String) {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        chat.title = String(clean.prefix(80))
        chat.titleIsCustom = true
        touch()
    }

    // MARK: Running

    private func start() {
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

        var tools: [any AgentTool] = []
        var repoContext: SystemPrompt.RepoContext?
        if let repo = chat.repo {
            guard let github = app.github.client else {
                fail(.signInNeeded, "Connect GitHub so MAIPA-G can read \(repo.ref.fullName).")
                return
            }
            do {
                let commit = try await github.resolveCommit(repo.ref, ref: repo.branch)
                let workspace = workspaceFor(repo: repo, commit: commit, github: github, store: app.snapshots)
                await workspace.prefetch()
                tools = [ListFilesTool(workspace: workspace), SearchCodeTool(workspace: workspace), ReadFileTool(workspace: workspace)]
                repoContext = SystemPrompt.RepoContext(
                    ref: repo.ref,
                    branch: repo.branch,
                    commit: commit,
                    isPrivate: repo.isPrivate,
                    summary: app.github.repo(named: repo.ref.fullName)?.summary
                )
            } catch {
                fail(.other, "Couldn't open \(repo.ref.fullName) on GitHub. \(app.github.describe(error))")
                return
            }
        }

        let lastMessage = chat.messages.last { $0.userText != nil }?.userText ?? ""
        let hasRepo = chat.repo != nil
        var difficulty = TaskDifficulty.estimate(lastMessage, hasRepo: hasRepo)
        if chat.model == .auto, app.openRouter.accountState.paidAllowed(),
           let judged = await OnDeviceAI.difficulty(of: lastMessage, hasRepo: hasRepo) {
            difficulty = judged
        }
        let catalogue = app.openRouter.modelsByID
        let thinking = chat.thinking
        let judgedDifficulty = difficulty
        let route = ModelRouter.route(choice: chat.model, difficulty: judgedDifficulty, thinking: thinking, account: app.openRouter.accountState, catalogue: catalogue)
        let input = AgentTurnInput(
            chat: chat,
            route: route,
            systemPrompt: SystemPrompt.make(userLogin: app.github.login, repo: repoContext),
            tools: tools,
            allowTools: app.openRouter.supportsTools(chat.model),
            spendLimit: app.settings.spendLimitOn ? app.settings.spendLimit : nil
        )
        let account = app.openRouter
        let environment = AgentEnvironment(
            openRouter: OpenRouterClient(transport: app.transport, apiKey: apiKey),
            freeRoute: {
                ModelRouter.route(choice: .free, difficulty: judgedDifficulty, thinking: thinking, account: AccountState(), catalogue: catalogue)
            },
            onOutOfCredits: { await account.markOutOfCredits() }
        )

        let run = AgentLoop.start(input, environment: environment)
        self.run = run
        for await event in run.events {
            guard case .updated(let turn, let milestone) = event else { continue }
            receive(turn, milestone: milestone)
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
