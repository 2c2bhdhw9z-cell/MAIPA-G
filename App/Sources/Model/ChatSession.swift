import AgentCore
import Foundation
import Observation
import UIKit

/// One open chat: its messages, what's typed in its box, and the AI working on it. A chat keeps
/// going while the user looks at other chats.
@MainActor
@Observable
final class ChatSession: Identifiable {
    enum BusySendMode: String, CaseIterable, Sendable {
        case steer
        case queue
    }

    let id: UUID
    private(set) var chat: Chat
    var draft = "" { didSet { scheduleDraftSave() } }
    var draftAttachments: [AttachmentReference] = [] { didSet { scheduleDraftSave() } }
    var webEnabled = true
    var autonomous = false
    /// Kiro-style mid-turn delivery mode (remembered per chat session, defaults to non-stopping `Steer`).
    var busySendMode: BusySendMode = .steer
    struct PendingSteer: Identifiable, Hashable, Sendable {
        let id = UUID()
        var text: String
    }

    private(set) var isRunning = false
    private(set) var isCompacting = false
    /// Spec mode: the current phase's document is written and waits for approval (reply or button).
    private(set) var specAwaitingApproval = false
    /// Supervised mode: staged files not yet reviewed.
    private(set) var unreviewedCount = 0
    /// The approve button already moved the spec on; the next turn must not move it again.
    @ObservationIgnored private var specApprovedByButton = false
    /// Staged files a restored checkpoint puts back once the repo copy is open again.
    @ObservationIgnored private var pendingStagedRestore: [StagedChange]?
    /// Unconsumed live steering notes waiting for the active run's next safe step boundary.
    private(set) var pendingSteers: [PendingSteer] = []
    /// Durable follow-up messages queued via `Queue` mode to run sequentially after the active turn finishes.
    private(set) var queuedSteering: [QueuedFollowUp] = []
    private(set) var mergeCheckStatus: String?
    private(set) var mergeWarning: String?
    var workstationFiles: [AttachmentReference] = []
    var activeWorkflowRuns: [ActiveWorkflowRunSnapshot] = []

    var savedFollowsBottom = true
    var savedAnchorMessageID: UUID?
    @ObservationIgnored weak var app: AppModel?
    @ObservationIgnored private var run: AgentRun?
    /// Set by Retry on a reply that stopped early: the next run carries that reply on instead of
    /// starting it again, and the model is told it was cut off.
    @ObservationIgnored private var pendingResumeNote: String?
    @ObservationIgnored private var workspace: RepoWorkspace?
    /// Observable without a receipt: true while the in-memory workspace has edits.
    private(set) var hasStagedChanges = false
    @ObservationIgnored private var stagedChangesRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var stagedChangesRefreshGeneration = 0
    @ObservationIgnored private var changeWorkspace: ChangeWorkspace? {
        didSet { refreshStagedChanges() }
    }
    /// Staged changes for the chat's other repos (Chat.additionalRepos), one per repo.
    @ObservationIgnored private var extraChangeWorkspaces: [RepoRef: ChangeWorkspace] = [:] {
        didSet { refreshStagedChanges() }
    }
    /// Every repo's staged changes, the chat's first repo first.
    private var allChangeWorkspaces: [ChangeWorkspace] {
        let extras = (chat.additionalRepos ?? []).compactMap { extraChangeWorkspaces[$0.ref] }
        return (changeWorkspace.map { [$0] } ?? []) + extras
    }
    @ObservationIgnored private var workflowEngines: [String: WorkflowEngine] = [:]
    @ObservationIgnored private var workflowTasks: [String: Task<Void, Never>] = [:]
    var currentChangeWorkspace: ChangeWorkspace? { changeWorkspace }
    var hasActiveWorkflowRuns: Bool { activeWorkflowRuns.contains(where: \.isRunning) }
    var hasInMemoryWorkToPreserve: Bool {
        changeWorkspace != nil || !extraChangeWorkspaces.isEmpty || !workstationFiles.isEmpty || !activeWorkflowRuns.isEmpty
    }

    func hasUnsavedStagedWork() async -> Bool {
        for changes in allChangeWorkspaces {
            if await changes.hasStagedChanges() { return true }
        }
        return false
    }

    func adoptSyncedChatMetadataPreservingWorkspace(_ synced: Chat) {
        chat.title = synced.title
        chat.titleIsCustom = synced.titleIsCustom
        chat.groupID = synced.groupID
        if synced.messages.count > chat.messages.count {
            chat.messages = synced.messages
        }
    }

    func liveModelAndRepoLines() -> [String] {
        guard let app else { return [] }
        let catalogue = app.openRouter.modelsByID
        let route = ModelRouter.route(
            choice: chat.model,
            difficulty: .normal,
            thinking: chat.thinking,
            account: app.openRouter.accountState,
            catalogue: catalogue,
            requiresImageInput: false,
            openRouterAvailable: app.openRouter.hasOpenRouterKey
        )
        let provider = app.openRouter.providerName(forModelID: route.model)
        let display = app.openRouter.displayName(forModelID: route.model)
        let info = catalogue[route.model]
        let ctxLen = info?.contextLength ?? route.contextBudget
        let maxOut = info?.maxCompletionTokens ?? route.maxOutputTokens ?? 16_384
        let effortLabel = route.effort?.rawValue ?? chat.thinking.rawValue
        var lines = [
            "Resolved model: \(display) (`\(route.model)`) via \(provider)",
            "Thinking effort: \(effortLabel) · Context window: \(ctxLen) tokens · Max output: \(maxOut) tokens",
            "Tools supported: \(app.openRouter.supportsTools(chat.model) ? "yes" : "no (text/image-only model)")",
        ]
        if let repo = chat.repo {
            let commitShort = workspace?.commit.prefix(7).description ?? "unloaded"
            lines.append("Chat repository: \(repo.ref.fullName) on branch \(repo.branch) (commit \(commitShort))")
        } else {
            lines.append("Chat repository: none attached")
        }
        if !workstationFiles.isEmpty {
            lines.append("Workstation files in chat: \(workstationFiles.count)")
        }
        for wf in activeWorkflowRuns {
            lines.append("Chat workflow \(wf.definition.name) (\(wf.id)): \(wf.isRunning ? "running" : (wf.checkpoint.pendingQuestion != nil ? "paused" : "stopped/done")) · cost $\(String(format: "%.4f", wf.checkpoint.cumulativeCost))")
        }
        return lines
    }
    /// What MAIPA-G last put on the chat computer, so unchanged staged edits aren't sent again.
    @ObservationIgnored private var lastComputerSync: String?
    @ObservationIgnored private var lastComputerCheck: Date?
    @ObservationIgnored private var changeSession: ChangeSession?
    @ObservationIgnored private var streamedTurns = StreamingUpdateBuffer<AssistantTurn>()
    @ObservationIgnored private var flushTask: Task<Void, Never>?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var draftSaveTask: Task<Void, Never>?
    @ObservationIgnored private var lastSaved = Date()
    @ObservationIgnored private var pausedInBackground = false
    @ObservationIgnored private var userStoppedExplicitly = false

    init(chat: Chat, app: AppModel?, draft: ComposerDraft? = nil) {
        self.id = chat.id
        self.chat = chat
        self.app = app
        self.draft = draft?.text ?? ""
        self.draftAttachments = draft?.attachments ?? []
        self.queuedSteering = chat.queuedFollowUps ?? []
        self.activeWorkflowRuns = chat.activeWorkflowRuns ?? []
        // Any run still marked "running" when a session is built has no in-memory engine behind it,
        // so settle it here: every load path builds a session, and the card would otherwise be stuck.
        settleInterruptedWorkflowRunsOnLaunch()
    }

    var backgroundStatusSubtitle: String {
        if let subs = lastTurn?.steps.reversed().flatMap({ $0.toolCalls.reversed() }).compactMap(\.subagents).first, !subs.isEmpty {
            let runningCount = subs.filter { $0.status == .running }.count
            let totalActions = subs.reduce(0) { $0 + $1.toolCallCount }
            let actionWord = totalActions == 1 ? "1 action" : "\(totalActions) actions"
            return runningCount > 0
                ? "Sub-agents (\(runningCount)/\(subs.count) running) · \(actionWord)"
                : "Sub-agents finishing · \(actionWord)"
        }
        if hasActiveWorkflowRuns {
            return "Running workflow in \(chat.title.isEmpty ? "chat" : chat.title)"
        }
        return chat.title.isEmpty ? "Finishing reply" : "Working in \(chat.title)"
    }

    func checkpointNow() async {
        flush(scheduleSave: false)
        guard let app else { return }
        lastSaved = Date()
        await app.library.save(chat)
    }

    private func syncQueuedFollowUpsToChat() {
        chat.queuedFollowUps = queuedSteering.isEmpty ? nil : queuedSteering
        saveSoon()
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
    private var estimatedPromptAndToolOverheadTokens: Int {
        let basePromptChars = 3_800 + chat.memoryContext.reduce(0) { $0 + $1.count + 4 } + (chat.repo != nil ? 1_400 : 0)
        var toolCount = webEnabled ? 2 : 0
        toolCount += 3 // ask_user, add_memory, edit_memory
        if chat.repo != nil { toolCount += 9 }
        if let app {
            if app.github.isConnected { toolCount += 3 }
            for conn in app.connectors.connected where app.connectors.states[conn.id] == .connected {
                let defs = app.connectors.toolDefinitions[conn.id] ?? []
                toolCount += defs.filter { !conn.disabledTools.contains($0.originalName) }.count
            }
            if app.openRouter.supportsTools(chat.model) { toolCount += 1 } // launch_helpers
        }
        // ~115 tokens per active tool schema + system prompt tokens
        return (basePromptChars / 4) + (toolCount * 115)
    }

    var contextUsedTokens: Int {
        // When older messages were compacted and no newer turn has reported usage yet, estimate from
        // system prompt + tool schemas + compacted summary + remaining uncompacted tail.
        if let compactedID = chat.compactedThroughMessageID,
           let cutIndex = chat.messages.firstIndex(where: { $0.id == compactedID }) {
            let tail = Array(chat.messages.dropFirst(cutIndex + 1))
            let newerTurnHasUsage = tail.compactMap(\.assistantTurn).flatMap(\.steps).compactMap(\.usage).isEmpty == false
            if !newerTurnHasUsage {
                let summaryChars = chat.compactedSummary?.count ?? 0
                let tailChars = tail.reduce(0) { total, message in
                    switch message.body {
                    case .user(let user): return total + user.text.count
                    case .assistant(let turn):
                        return total + turn.steps.reduce(0) { partial, step in
                            partial + step.text.count + step.toolCalls.reduce(0) { $0 + $1.arguments.count + min($1.result?.count ?? 0, 24_000) }
                        }
                    }
                }
                return max(0, estimatedPromptAndToolOverheadTokens + Int(Double(summaryChars + tailChars) / 3.6))
            }
        }
        // The latest request's prompt already includes system prompt + tool schemas + history.
        if let usage = chat.messages.reversed().compactMap(\.assistantTurn).flatMap({ $0.steps.reversed() }).compactMap(\.usage).first {
            return max(0, usage.promptTokens + usage.completionTokens)
        }
        let characters = chat.messages.reduce(0) { total, message in
            switch message.body {
            case .user(let user): return total + user.text.count
            case .assistant(let turn):
                return total + turn.steps.reduce(0) { partial, step in
                    partial + step.text.count + step.toolCalls.reduce(0) { $0 + $1.arguments.count + min($1.result?.count ?? 0, 24_000) }
                }
            }
        }
        if chat.messages.isEmpty { return 0 }
        return max(0, estimatedPromptAndToolOverheadTokens + Int(Double(characters) / 3.6))
    }
    var isWaitingForAnswers: Bool { lastTurn?.pendingQuestions != nil }
    var isWaitingOnSpend: Bool { lastTurn?.status == .waitingForUser && lastTurn?.spendCheck != nil }

    // MARK: What the user does

    func send(_ text: String, attachments: [AttachmentReference] = []) {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty || !attachments.isEmpty else { return }
        if isRunning {
            // Kiro-style mid-turn controls:
            // - `Steer` (default for text): folds guidance into the active turn at the next safe boundary
            //   WITHOUT calling `finishAfterCurrentStep()` or cancelling any running stream/sub-agent/tool!
            // - `Queue` (or attachments): holds follow-up on disk to run sequentially after the active turn finishes naturally.
            if busySendMode == .steer, attachments.isEmpty {
                pendingSteers.append(PendingSteer(text: message))
                if let activeRun = run {
                    Task { await activeRun.steer(message) }
                }
            } else {
                queuedSteering.append(QueuedFollowUp(text: message, attachments: attachments))
                syncQueuedFollowUpsToChat()
            }
            return
        }
        pausedInBackground = false
        userStoppedExplicitly = false
        specAwaitingApproval = false
        settleWaitingTurn()
        chat.messages.append(.user(message, attachments: attachments))
        chat.messages.append(ChatMessage(body: .assistant(AssistantTurn())))
        if chat.title.isEmpty {
            chat.title = message.isEmpty ? Self.provisionalAttachmentTitle(attachments) : Self.provisionalTitle(message)
        }
        touch()
        start()
    }

    /// Cancels a pending unconsumed steer before the next step boundary consumes it and restores it to the composer.
    func cancelPendingSteer(_ id: UUID) {
        guard let index = pendingSteers.firstIndex(where: { $0.id == id }) else { return }
        let removed = pendingSteers.remove(at: index).text
        if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            draft = removed
        } else {
            draft = draft + "\n" + removed
        }
        if let activeRun = run {
            Task { _ = await activeRun.removeSteering(removed) }
        }
    }

    /// Cancels a queued follow-up item and restores its text and attachments back to the composer for editing.
    func cancelQueuedFollowUp(_ id: UUID) {
        guard let idx = queuedSteering.firstIndex(where: { $0.id == id }) else { return }
        let item = queuedSteering.remove(at: idx)
        syncQueuedFollowUpsToChat()
        if !item.text.isEmpty {
            if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                draft = item.text
            } else {
                draft = draft + "\n" + item.text
            }
        }
        if !item.attachments.isEmpty {
            let existingIDs = Set(draftAttachments.map(\.id))
            for att in item.attachments where !existingIDs.contains(att.id) {
                draftAttachments.append(att)
            }
        }
    }

    func clearQueuedSteering() {
        queuedSteering.removeAll()
        syncQueuedFollowUpsToChat()
    }

    func resumeInterruptedTurn() {
        guard !isRunning, pausedInBackground, var turn = lastTurn else { return }
        pausedInBackground = false
        guard turn.status == .stopped || turn.status == .running else { return }
        turn.status = .running
        replaceLastTurn(turn)
        start()
    }

    /// The reply was still going when the app was closed. Continue it, unless that just crashed.
    func resumeFromRelaunchIfSafe() {
        guard !isRunning, lastTurn?.status == .running else { return }
        let key = Self.autoResumeKey(chat.id)
        let now = Date().timeIntervalSince1970
        let last = UserDefaults.standard.double(forKey: key)
        if last > 0, now - last < 45 {
            settleInterruptedTurnOnLaunch()
            return
        }
        UserDefaults.standard.set(now, forKey: key)
        pausedInBackground = false
        start()
    }

    private static func autoResumeKey(_ id: UUID) -> String {
        "maipag.autoresume.\(id.uuidString)"
    }

    /// Settles a cold-launch `.running` turn left behind when the app previously closed or crashed so
    /// startup never triggers an automatic background re-run or crash loop. The user can tap "Keep going"
    /// or "Retry this answer" whenever they want to continue it.
    func settleInterruptedTurnOnLaunch() {
        guard !isRunning, var turn = lastTurn, turn.status == .running else { return }
        let finishedAt = Date()
        for stepIdx in turn.steps.indices {
            for callIdx in turn.steps[stepIdx].toolCalls.indices {
                let existing = turn.steps[stepIdx].toolCalls[callIdx]
                let hasRunningSubagents = existing.subagents?.contains(where: { $0.status == .running }) == true
                guard existing.status == .running || hasRunningSubagents else { continue }
                var record = existing
                record.status = .done
                if record.detail == nil || record.detail?.isEmpty == true {
                    record.detail = "Paused when the app closed"
                }
                if var subs = record.subagents {
                    for sIdx in subs.indices where subs[sIdx].status == .running {
                        subs[sIdx].status = .cancelled
                        subs[sIdx].latestActivity = "Stopped"
                    }
                    record.subagents = subs
                } else if record.name == "launch_helpers" {
                    record.subagents = SubagentRunItem.resolvedItems(for: record).map { item in
                        var copy = item
                        if copy.status == .running {
                            copy.status = .cancelled
                            copy.latestActivity = "Stopped"
                        }
                        return copy
                    }
                }
                if record.result == nil || hasRunningSubagents {
                    if record.name == "launch_helpers" {
                        let actionsDone = (record.subagents ?? []).reduce(0) { $0 + $1.toolCallCount }
                        let progressNote = actionsDone > 0 ? " after \(actionsDone) actions of partial progress" : ""
                        record.result = "Paused when the app closed\(progressNote) (not a tool failure). Sub-agent launching works normally — launch sub-agents in parallel to continue."
                    } else {
                        record.result = "Paused when the app closed."
                    }
                }
                let baseSummary = record.summary.replacingOccurrences(of: "…", with: "").trimmingCharacters(in: .whitespaces)
                if !baseSummary.lowercased().contains("stopped"), !baseSummary.lowercased().contains("paused") {
                    record.summary = baseSummary.isEmpty ? "Paused" : "\(baseSummary) · paused"
                }
                if record.finishedAt == nil {
                    record.finishedAt = finishedAt
                }
                turn.steps[stepIdx].toolCalls[callIdx] = record
            }
            if turn.steps[stepIdx].finishedAt == nil {
                turn.steps[stepIdx].finishedAt = finishedAt
            }
        }
        turn.status = .stopped
        replaceLastTurn(turn)
        saveSoon(immediately: true)
    }

    func stagedDiff() async -> String {
        let all = allChangeWorkspaces
        guard all.count > 1 else { return await changeWorkspace?.stagedDiff() ?? "No staged changes in this turn." }
        // Several repos: each repo's changes under its own heading, as each is saved on its own.
        var sections: [String] = []
        for changes in all {
            var diff = "No staged changes."
            if await changes.hasStagedChanges() { diff = await changes.stagedDiff() }
            sections.append("=== \(changes.base.repo.fullName) (\(changes.base.repo.hostName), \(changes.base.branch)) ===\n" + diff)
        }
        return sections.joined(separator: "\n\n")
    }

    /// Cheap actor query, never awaited by the token-delivery path. A replaced workspace
    /// or newer refresh invalidates the old result before it can change visibility.
    func refreshStagedChanges() {
        stagedChangesRefreshGeneration &+= 1
        let generation = stagedChangesRefreshGeneration
        stagedChangesRefreshTask?.cancel()
        stagedChangesRefreshTask = nil
        let all = allChangeWorkspaces
        guard !all.isEmpty else {
            hasStagedChanges = false
            return
        }
        let changes = changeWorkspace
        stagedChangesRefreshTask = Task { [weak self] in
            var hasChanges = false
            for workspace in all {
                if await workspace.hasStagedChanges() { hasChanges = true; break }
            }
            guard !Task.isCancelled, let self,
                  self.stagedChangesRefreshGeneration == generation,
                  self.changeWorkspace === changes else { return }
            self.hasStagedChanges = hasChanges
            self.stagedChangesRefreshTask = nil
        }
    }

    func currentStagedChanges() async -> [StagedChange] {
        defer { refreshStagedChanges() }
        return await changeWorkspace?.stagedChanges() ?? []
    }

    func branchDiff() async -> String {
        let repos = chat.allRepos
        guard !repos.isEmpty else { return "Connect GitHub to load the branch diff." }
        guard repos.count > 1 else { return await branchDiff(for: repos[0]) }
        var sections: [String] = []
        for repo in repos {
            sections.append("=== \(repo.ref.fullName) (\(repo.ref.hostName)) ===\n" + (await branchDiff(for: repo)))
        }
        return sections.joined(separator: "\n\n")
    }

    private func branchDiff(for repo: ChatRepo) async -> String {
        guard let app, let github = app.repoClient(for: repo.ref) else { return "Connect \(repo.ref.hostName) to load the branch diff." }
        let branch = (chat.saveReceipts ?? []).last { $0.repo == repo.ref && $0.pullRequest != nil && $0.resolution == nil }?.branch ?? repo.branch
        do {
            let comparison = try await github.compare(repo.ref, base: repo.defaultBranch, head: branch)
            if comparison.files.isEmpty { return "No branch changes." }
            return ChangeWorkspace.capped(
                comparison.files.map { file in
                    "--- \(file.status): \(file.path)\n" + (file.patch ?? "\(repo.ref.hostName) did not provide a text patch for this file.")
                }.joined(separator: "\n\n"),
                hint: "\(comparison.files.count) files changed on this branch; open the file on \(repo.ref.hostName) to see the rest."
            )
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
        pausedInBackground = false
        userStoppedExplicitly = true
        pendingSteers.removeAll()
        flush()
        guard isRunning else {
            settleWaitingTurn()
            return
        }
        // A workflow the chat started runs in the chat with no agent run to cancel; Stop stops it.
        if run == nil, let routeLabel = lastTurn?.routeLabel, routeLabel.hasPrefix("Workflow · ") {
            for workflowRun in activeWorkflowRuns where workflowRun.isRunning { stopWorkflowRun(workflowRun.id) }
        }
        run?.cancel()
    }

    func suspendForBackgroundIfNeeded() {
        guard isRunning else { return }
        if app?.backgroundJobs.isContinuedProcessingActive == true {
            return
        }
        suspendForBackground()
    }

    private func suspendForBackground() {
        guard isRunning else { return }
        pausedInBackground = true
        flush()
        saveSoon(immediately: true)
        run?.cancel()
    }

    /// Runs any saved answer again, rewinding messages after it while preserving compacted earlier
    /// session memory whenever the compacted cutoff precedes the retried message.
    func retryAnswer(_ messageID: UUID) {
        guard !isRunning, !isCompacting,
              let index = chat.messages.firstIndex(where: { $0.id == messageID }),
              chat.messages[index].assistantTurn != nil else { return }
        // A latest reply that stopped early carries on from where it stopped, rather than being
        // thrown away and started over. The model is told it was cut off; "Keep going" is still
        // the person's own message, so the two are different to it.
        if index == chat.messages.count - 1,
           let turn = chat.messages[index].assistantTurn, turn.stoppedEarly == true {
            let partial = turn.steps.last(where: { !$0.text.isEmpty })?.text ?? ""
            pendingResumeNote = AgentLoop.resumeNote(partialText: partial)
            touch()
            start()
            return
        }
        chat.messages.removeSubrange(index...)
        chat.messages.append(ChatMessage(body: .assistant(AssistantTurn())))
        pruneInvalidatedCompactionAfterRewind()
        touch()
        start()
    }

    func editAndResend(_ messageID: UUID, text: String) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isRunning, !isCompacting, !clean.isEmpty,
              let index = chat.messages.firstIndex(where: { $0.id == messageID }),
              case .user(let original) = chat.messages[index].body else { return }
        chat.messages.removeSubrange(index...)
        chat.messages.append(ChatMessage(body: .user(UserMessage(text: clean, attachments: original.attachments))))
        chat.messages.append(ChatMessage(body: .assistant(AssistantTurn())))
        pruneInvalidatedCompactionAfterRewind()
        touch()
        start()
    }

    private func pruneInvalidatedCompactionAfterRewind() {
        if let compactedID = chat.compactedThroughMessageID,
           !chat.messages.contains(where: { $0.id == compactedID }) {
            if let prevID = chat.previousCompactedThroughMessageID,
               let prevSummary = chat.previousCompactedSummary,
               chat.messages.contains(where: { $0.id == prevID }) {
                chat.compactedSummary = prevSummary
                chat.compactedThroughMessageID = prevID
            } else {
                chat.compactedSummary = nil
                chat.compactedThroughMessageID = nil
            }
            chat.previousCompactedSummary = nil
            chat.previousCompactedThroughMessageID = nil
        }
        // A summary whose pointer is gone entirely can't be placed in the transcript either.
        if chat.compactedSummary != nil, chat.compactedThroughMessageID == nil {
            chat.compactedSummary = nil
        }
    }

    private var compactableRangeEndIndex: Int? {
        guard chat.messages.count > 4 else { return nil }
        let keepTail = 4
        let throughIndex = chat.messages.count - keepTail - 1
        guard throughIndex >= 1 else { return nil }
        let startIndex: Int
        if let prevID = chat.compactedThroughMessageID,
           let prevIdx = chat.messages.firstIndex(where: { $0.id == prevID }) {
            startIndex = prevIdx + 1
        } else {
            startIndex = 0
        }
        // Only enable Compact when at least 2 uncompacted older messages exist before the 4-message live tail.
        guard throughIndex - startIndex + 1 >= 2 else { return nil }
        return throughIndex
    }

    var canCompact: Bool { !isRunning && !isCompacting && compactableRangeEndIndex != nil }
    var canUncompact: Bool { !isRunning && !isCompacting && chat.compactedSummary != nil }

    func compact() {
        guard canCompact else { return }
        Task { await performStructuredCompaction() }
    }

    func restoreFullMemory() {
        guard canUncompact else { return }
        chat.compactedSummary = nil
        chat.compactedThroughMessageID = nil
        chat.previousCompactedSummary = nil
        chat.previousCompactedThroughMessageID = nil
        appendNotice("Restored full conversation memory — all earlier messages are included in future AI requests again.")
        touch()
    }

    func undoLastCompaction() {
        guard canUncompact else { return }
        if let prevSummary = chat.previousCompactedSummary, let prevThrough = chat.previousCompactedThroughMessageID {
            chat.compactedSummary = prevSummary
            chat.compactedThroughMessageID = prevThrough
            chat.previousCompactedSummary = nil
            chat.previousCompactedThroughMessageID = nil
            appendNotice("Undid the latest compaction and restored the previous session summary.")
        } else {
            restoreFullMemory()
            return
        }
        touch()
    }

    private func performStructuredCompaction() async {
        guard !isCompacting, !isRunning,
              let throughIndex = compactableRangeEndIndex,
              chat.messages.indices.contains(throughIndex) else { return }
        let targetThroughMessageID = chat.messages[throughIndex].id
        isCompacting = true
        defer { isCompacting = false }

        let prevSummary = chat.compactedSummary
        let prevThrough = chat.compactedThroughMessageID
        let startIndex: Int
        if let prevID = prevThrough, let prevIdx = chat.messages.firstIndex(where: { $0.id == prevID }) {
            startIndex = prevIdx + 1
        } else {
            startIndex = 0
        }
        let slice = Array(chat.messages[startIndex...throughIndex])
        guard !slice.isEmpty else { return }

        var transcriptBlocks: [String] = []
        if let prevSummary, !prevSummary.isEmpty {
            transcriptBlocks.append("=== EARLIER SESSION MEMORY ===\n\(prevSummary)")
        }
        for (idx, message) in slice.enumerated() {
            switch message.body {
            case .user(let user):
                let attNames = user.attachments.map(\.name)
                let attNote = attNames.isEmpty ? "" : " [Attachments: \(attNames.joined(separator: ", "))]"
                transcriptBlocks.append("Turn \(idx + 1) — User\(attNote):\n\(String(user.text.prefix(12_000)))")
            case .assistant(let turn):
                var parts: [String] = []
                for step in turn.steps {
                    for call in step.toolCalls {
                        let resSnippet = (call.result ?? "").prefix(600).replacingOccurrences(of: "\n", with: " ")
                        parts.append("• Tool `\(call.name)` (\(call.summary)): \(resSnippet)")
                    }
                    let cleanText = step.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !cleanText.isEmpty {
                        parts.append(String(cleanText.prefix(12_000)))
                    }
                }
                if !parts.isEmpty {
                    transcriptBlocks.append("Turn \(idx + 1) — Assistant:\n\(parts.joined(separator: "\n"))")
                }
            }
        }
        let combinedHistory = transcriptBlocks.joined(separator: "\n\n---\n\n")
        guard !combinedHistory.isEmpty else { return }

        var aiSummary: String?
        if let app, app.openRouter.isSignedIn {
            let catalogue = app.openRouter.modelsByID
            let route = ModelRouter.route(
                choice: chat.model,
                difficulty: .normal,
                thinking: .low,
                account: app.openRouter.accountState,
                catalogue: catalogue,
                requiresImageInput: false,
                openRouterAvailable: app.openRouter.hasOpenRouterKey
            )
            let budgetChars = max(48_000, min(route.contextBudget * 3, 450_000))
            let boundedHistory: String
            if combinedHistory.count > budgetChars {
                let half = budgetChars / 2
                boundedHistory = String(combinedHistory.prefix(half)) + "\n\n[... middle turns condensed ...]\n\n" + String(combinedHistory.suffix(half))
            } else {
                boundedHistory = combinedHistory
            }
            let summarySystem = """
            You are compacting earlier messages of an active coding/assistant session into high-density structured session memory.
            Preserve ALL concrete facts, file paths, branch/PR/build numbers, user rules/corrections, decisions, errors/dead ends, and unfinished tasks so continuation is seamless.
            Write concise Markdown using these exact sections:
            # Current State
            # Task & Acceptance Criteria
            # User Rules & Preferences
            # Files, Architecture & Findings
            # Actions Taken & Key Results
            Output ONLY the structured Markdown summary — no preamble.
            """
            let req = ChatCompletionRequest(
                model: route.model,
                messages: [
                    .system(summarySystem),
                    .user("Summarize this earlier session history without losing important technical details, rules, or unfinished items:\n\n\(boundedHistory)"),
                ],
                reasoningEffort: route.effort == nil ? nil : .low
            )
            if let stream = try? await app.openRouter.client.stream(req) {
                var acc = ""
                var streamFailed = false
                var sawErrorFinish = false
                do {
                    for try await chunk in stream {
                        if let err = chunk.error { throw err }
                        if let d = chunk.contentDelta { acc += d }
                        if chunk.finishReason == "error" || chunk.finishReason == "content_filter" {
                            sawErrorFinish = true
                        }
                    }
                } catch {
                    streamFailed = true
                }
                let trimmed = acc.trimmingCharacters(in: .whitespacesAndNewlines)
                if !streamFailed, !sawErrorFinish, trimmed.count >= 80, trimmed.contains("# ") {
                    aiSummary = trimmed
                }
            }
        }

        // Re-verify target message ID after async suspension so concurrent rewinds/deletions can never crash on a stale index.
        guard !isRunning,
              let verifiedIndex = chat.messages.firstIndex(where: { $0.id == targetThroughMessageID }) else {
            return
        }

        let finalSummary: String
        if let aiSummary {
            finalSummary = aiSummary
        } else {
            // Structured offline fallback covering the full slice (head + tail across every turn, never chopping at 18K).
            let fallbackLines = transcriptBlocks.map { String($0.prefix(2_400)) }.joined(separator: "\n\n")
            finalSummary = "# Session Digest (Offline Fallback)\n\n" + String(fallbackLines.suffix(48_000))
        }

        chat.previousCompactedSummary = prevSummary
        chat.previousCompactedThroughMessageID = prevThrough
        chat.compactedSummary = finalSummary
        chat.compactedThroughMessageID = targetThroughMessageID
        let keptTailCount = max(0, chat.messages.count - 1 - verifiedIndex)
        appendNotice("Compacted \(slice.count) older messages into structured session memory (keeping the latest \(keptTailCount) messages verbatim). Tap the Context ring anytime to restore full memory.")
        touch()
    }

    /// Runs the last message again, after a failure.
    func retry() {
        guard !isRunning, let last = chat.messages.last, last.assistantTurn != nil else { return }
        // "Try again" on a reply that stopped early carries it on, the same as "Retry this answer",
        // instead of throwing away what it already did.
        if last.assistantTurn?.stoppedEarly == true {
            retryAnswer(last.id)
            return
        }
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

    /// This chat's mode: Vibe unless the chat was set to Spec. Remembered per chat, so a chat that
    /// plans keeps planning and a chat that just does it keeps doing it.
    var mode: ChatMode {
        get { ChatMode(rawValue: chat.mode ?? "") ?? .vibe }
        set {
            // Locked while a reply runs, as Kiro disables its agent selector during a run
            // (https://kiro.dev/docs/ide/chat/). Owner, 11 November 2026.
            guard !isRunning else { return }
            chat.mode = newValue.rawValue
            touch()
        }
    }

    /// The modes the picker offers: always both. Owner, 11 November 2026 (Kiro parity): Kiro has no
    /// switch that hides Spec; Vibe and Spec can be flipped at any point in a chat
    /// (https://kiro.dev/docs/ide/chat/ "Switching agents mid-session"), and the next message uses
    /// the new mode with the whole conversation kept.
    var availableModes: [ChatMode] { [.vibe, .spec] }

    /// The mode this chat runs in: whatever was picked, Vibe by default.
    var effectiveMode: ChatMode { mode }

    /// The Kiro spec workflow: the chat's spec's own, else the one picked, else Requirements-First.
    var specKind: KiroSpecKind { chat.kiroSpec?.kind ?? chat.kiroSpecKind ?? .requirementsFirst }
    /// Kiro: the workflow can't be switched once a spec has started (https://kiro.dev/docs/specs/best-practices/).
    var specKindLocked: Bool { chat.kiroSpec != nil || isRunning }

    func setSpecKind(_ kind: KiroSpecKind) {
        guard !specKindLocked else { return }
        chat.kiroSpecKind = kind
        touch()
    }

    /// Autopilot or Supervised (https://kiro.dev/docs/ide/chat/autopilot/).
    var permissionMode: PermissionMode { chat.permissionMode ?? .autopilot }

    func setPermissionMode(_ newValue: PermissionMode) {
        guard !isRunning else { return }
        chat.permissionMode = newValue == .autopilot ? nil : newValue
        touch()
        Task { await refreshReviewState() }
    }

    static let supervisedInstructions = """


    ## Supervised mode (this chat)
    The person reviews every change before it is saved, the way Kiro's Supervised mode works. Stage \
    changes with the file tools as usual, but don't call `save_changes` until they have accepted \
    them: `save_changes` refuses while any staged file is unreviewed. When your changes are staged, \
    finish the reply and say they are ready to review. After they accept (and ask), save.
    """

    // MARK: Spec approval button

    /// "Approve requirements → design", shown when the current document waits for approval.
    var specApprovalTitle: String? {
        guard effectiveMode == .spec, specAwaitingApproval, !isRunning, let state = chat.kiroSpec else { return nil }
        return KiroSpecs.approvalButtonTitle(state)
    }

    /// The button does what a "looks good" reply does, and the approval is posted in the chat too.
    func approveSpecPhase() {
        guard !isRunning, let state = chat.kiroSpec, KiroSpecs.approvalButtonTitle(state) != nil else { return }
        chat.kiroSpec = KiroSpecs.approved(state, currentDocumentExists: true)
        specAwaitingApproval = false
        specApprovedByButton = true
        touch()
        send(KiroSpecs.approvalMessage(state))
    }

    // MARK: Supervised review

    private var acceptedSet: Set<String> { Set(chat.acceptedChanges ?? []) }

    /// Paths of staged files (every repo of the chat) not accepted yet.
    func unreviewedPaths() async -> [String] {
        guard permissionMode == .supervised else { return [] }
        var staged: [StagedChange] = []
        for workspace in allChangeWorkspaces { staged += await workspace.stagedChanges() }
        return SupervisedReview.unreviewed(staged, accepted: acceptedSet).map(\.path)
    }

    func refreshReviewState() async {
        var staged: [StagedChange] = []
        for workspace in allChangeWorkspaces { staged += await workspace.stagedChanges() }
        let pruned = SupervisedReview.pruned(acceptedSet, staged: staged)
        if pruned != acceptedSet { chat.acceptedChanges = pruned.isEmpty ? nil : Array(pruned).sorted(); touch() }
        unreviewedCount = permissionMode == .supervised ? SupervisedReview.unreviewed(staged, accepted: pruned).count : 0
        refreshStagedChanges()
    }

    /// The staged files of the chat's main repo, hunk by hunk, for the review screen.
    func reviewFiles() async -> [ReviewFile] {
        guard let workspace = changeWorkspace else { return [] }
        var files: [ReviewFile] = []
        for change in await workspace.stagedChanges() {
            let texts = await workspace.reviewTexts(change.path)
            files.append(SupervisedReview.file(for: change, texts: texts, accepted: acceptedSet))
        }
        return files
    }

    func acceptReviewFile(_ path: String) async {
        guard let workspace = changeWorkspace,
              let change = await workspace.stagedChanges().first(where: { $0.path == path }) else { return }
        var accepted = acceptedSet
        accepted.insert(SupervisedReview.fingerprint(change))
        chat.acceptedChanges = Array(accepted).sorted()
        touch()
        await refreshReviewState()
    }

    func acceptAllReview() async {
        var accepted = acceptedSet
        for workspace in allChangeWorkspaces {
            for change in await workspace.stagedChanges() { accepted.insert(SupervisedReview.fingerprint(change)) }
        }
        chat.acceptedChanges = accepted.isEmpty ? nil : Array(accepted).sorted()
        touch()
        await refreshReviewState()
    }

    /// Kiro's per-hunk reject: that part of the staged file goes back to how the repo has it.
    func rejectReviewHunk(path: String, hunk: ReviewHunk) async {
        guard let workspace = changeWorkspace, let texts = await workspace.reviewTexts(path) else { return }
        let change = await workspace.stagedChanges().first { $0.path == path }
        if case .delete? = change {
            await workspace.unstage(path)
        } else {
            do { try await workspace.revertPart(path: path, text: SupervisedReview.rejecting(hunk, new: texts.new)) }
            catch { appendNotice("Couldn't reject that change: \(ErrorExplainer.explain(error).message)") }
        }
        await refreshReviewState()
    }

    /// Rejects every change to one file.
    func rejectReviewFile(_ path: String) async {
        guard let workspace = changeWorkspace else { return }
        await workspace.unstage(path)
        await refreshReviewState()
    }

    // MARK: Checkpoints (https://kiro.dev/docs/checkpoints/)

    func hasCheckpoint(_ messageID: UUID) -> Bool {
        chat.checkpoints?.contains { $0.messageID == messageID } == true
    }

    /// Saves pushed after this checkpoint that restoring could undo.
    func savesAfterCheckpoint(_ messageID: UUID) -> Int {
        guard let checkpoint = chat.checkpoints?.first(where: { $0.messageID == messageID }) else { return 0 }
        return ChatCheckpoints.savesToUndo(after: checkpoint, receipts: chat.saveReceipts ?? []).count
    }

    /// One checkpoint per message, taken before the reply runs.
    private func captureCheckpoint() async {
        guard let message = chat.messages.last(where: { $0.userText != nil }), !hasCheckpoint(message.id) else { return }
        let staged = await changeWorkspace?.stagedChanges() ?? []
        let checkpoint = ChatCheckpoint(messageID: message.id, staged: staged, saveCount: chat.saveReceipts?.count ?? 0, kiroSpec: chat.kiroSpec, acceptedChanges: chat.acceptedChanges)
        chat.checkpoints = ChatCheckpoints.adding(checkpoint, to: chat.checkpoints ?? [])
    }

    /// Restores files and conversation to just before this message, as Kiro's Restore does. The
    /// message goes back into the box. With `undoSaves`, saves pushed since then are undone too.
    func restoreCheckpoint(_ messageID: UUID, undoSaves: Bool) async {
        guard !isRunning, !isCompacting,
              let checkpoint = chat.checkpoints?.first(where: { $0.messageID == messageID }),
              chat.messages.contains(where: { $0.id == messageID }) else { return }
        var notes: [String] = []
        if undoSaves {
            for receipt in ChatCheckpoints.savesToUndo(after: checkpoint, receipts: chat.saveReceipts ?? []) {
                if let problem = await undoSave(receipt.id) {
                    notes.append("A save after this point couldn't be undone, so it stays: \(problem)")
                    break
                }
            }
        } else if savesAfterCheckpoint(messageID) > 0 {
            notes.append("Saves made after this point are still in the repo.")
        }
        if checkpoint.filesComplete {
            if let workspace = changeWorkspace {
                await workspace.restoreStaged(checkpoint.stagedChanges)
            } else if !checkpoint.files.isEmpty {
                pendingStagedRestore = checkpoint.stagedChanges
            }
        } else {
            notes.append("The staged files at this point were too big to keep, so files weren't restored.")
        }
        guard let index = chat.messages.firstIndex(where: { $0.id == messageID }) else { return }
        let original = chat.messages[index].userText ?? ""
        chat.messages.removeSubrange(index...)
        chat.kiroSpec = checkpoint.kiroSpec
        chat.acceptedChanges = checkpoint.acceptedChanges
        chat.checkpoints = ChatCheckpoints.kept(chat.checkpoints ?? [], messageIDs: Set(chat.messages.map(\.id)))
        specAwaitingApproval = false
        pruneInvalidatedCompactionAfterRewind()
        if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { draft = original }
        appendNotice((["Restored the checkpoint: files and conversation are back to before that message."] + notes).joined(separator: " "))
        touch()
        await refreshReviewState()
    }

    /// Added to the system prompt in Spec mode when the chat has no repo to hold spec files:
    /// plan first, inside the chat, then build on "go".
    static let specModeInstructions = """


    ## Spec mode (this chat)
    The person chose Spec for this chat. For any request to build or change something, first write \
    short requirements and a numbered plan (what changes, where, and how it will be checked), show \
    them, and stop: make no file changes and run nothing that changes anything until the person \
    says go (for example "go", "yes", "build it", "looks good"). Once they approve, build exactly \
    that plan, and say if you have to depart from it. Plain questions are answered directly; they \
    need no plan.
    """

    /// The Spec-mode part of the system prompt: Kiro's three-file spec flow when the chat has a repo,
    /// otherwise a plan written in the chat.
    private func specModeSection(hasRepo: Bool, existingSpecs: [String]) -> String {
        guard effectiveMode == .spec else { return "" }
        guard hasRepo else {
            return Self.specModeInstructions + " Spec files (`.kiro/specs/<feature>/requirements.md`, `design.md`, `tasks.md`) need a repo; this chat has none, so plan in the chat."
        }
        return KiroSpecs.instructions(state: chat.kiroSpec, existingSpecs: existingSpecs, kind: specKind)
    }

    /// One line under a Spec-mode reply saying which document waits for approval and how to give it.
    static func specPhaseNotice(_ state: KiroSpecState, workspace: ChangeWorkspace) async -> String? {
        guard let path = state.path(state.phase) else {
            guard case .text(let text, _) = try? await workspace.read(state.path(.tasks) ?? "") else { return nil }
            let tasks = KiroSpecs.tasks(in: text)
            guard !tasks.isEmpty else { return nil }
            return "Spec \(state.slug): \(tasks.filter(\.isDone).count) of \(tasks.count) tasks done in \(state.path(.tasks) ?? "")."
        }
        guard case .text = try? await workspace.read(path) else { return nil }
        let next: String
        switch state.nextPhase {
        case .some(.implementation), .none: next = "start building"
        case .some(let phase): next = "move on to the \(state.title(phase).lowercased())"
        }
        let button = KiroSpecs.approvalButtonTitle(state).map { " or tap \u{201C}\($0)\u{201D}" } ?? ""
        return "Spec \(state.slug): \(path) is ready for review. Reply \u{201C}looks good\u{201D}\(button) to \(next), or say what to change."
    }

    func setRepo(_ repo: ChatRepo?) {
        chat.repo = repo
        workspace = nil
        changeWorkspace = nil
        changeSession = nil
        if repo == nil {
            // More repos only ride along with a first one.
            chat.additionalRepos = nil
            extraChangeWorkspaces = [:]
        } else if let repo, chat.additionalRepos?.contains(where: { $0.ref == repo.ref }) == true {
            setAdditionalRepos((chat.additionalRepos ?? []).filter { $0.ref != repo.ref })
            return
        }
        touch()
    }

    /// The chat's other repos. A repo taken off loses its staged (unsaved) changes; saved work stays.
    func setAdditionalRepos(_ repos: [ChatRepo]) {
        let kept = repos.filter { $0.ref != chat.repo?.ref }
        chat.additionalRepos = kept.isEmpty ? nil : kept
        let refs = Set(kept.map(\.ref))
        var remaining: [RepoRef: ChangeWorkspace] = [:]
        for (ref, changes) in extraChangeWorkspaces where refs.contains(ref) {
            // A changed branch starts that repo's staged changes afresh.
            if kept.first(where: { $0.ref == ref })?.branch == changes.base.branch { remaining[ref] = changes }
        }
        extraChangeWorkspaces = remaining
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
        guard let app, var receipts = chat.saveReceipts,
              let index = receipts.indices.last, let pull = receipts[index].pullRequest, receipts[index].resolution == nil,
              let github = app.repoClient(for: receipts[index].repo) else { return }
        let isGitLab = receipts[index].repo.isGitLab
        let requestName = isGitLab ? "merge request !\(pull.number)" : "pull request #\(pull.number)"
        do {
            if isGitLab, let lab = app.gitlab.client {
                // GitLab runs pipelines instead of GitHub checks.
                let status = try await lab.pipelineStatus(receipts[index].repo, commit: receipts[index].savedCommit)
                switch status {
                case nil: mergeCheckStatus = "No pipeline"
                case "success", "skipped", "manual": mergeCheckStatus = "Pipeline passed"
                default:
                    mergeCheckStatus = status == "failed" || status == "canceled" ? "Pipeline \(status ?? "")" : "Pipeline is \(status ?? "pending")"
                    if !force {
                        mergeWarning = "\(mergeCheckStatus ?? "The pipeline did not pass"). Add \(requestName) anyway?"
                        return
                    }
                }
                try await GitHubChangeService(github: github).addIt(receipts[index])
                receipts[index].resolution = "added"
                chat.saveReceipts = receipts
                mergeWarning = nil
                appendNotice("Added the merge request and removed its side branch.")
                return
            }
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
            if let api = error as? GitHubAPIError, api.status == 409 || api.status == 422 || (isGitLab && (api.status == 405 || api.status == 406)) {
                appendNotice("\(receipts[index].repo.hostName) could not merge \(requestName): \(explanation.cause) Open it, resolve the named conflicting files, then tap Add it again. \(pull.htmlURL)")
            } else {
                appendNotice("Couldn’t add \(requestName): \(explanation.message)")
            }
        }
    }

    func cancelMergeWarning() { mergeWarning = nil }

    func throwAwayLastSave() async {
        guard let app, var receipts = chat.saveReceipts,
              let index = receipts.indices.last, receipts[index].pullRequest != nil, receipts[index].resolution == nil,
              let github = app.repoClient(for: receipts[index].repo) else { return }
        let repo = receipts[index].repo
        do {
            try await GitHubChangeService(github: github).throwAway(receipts[index])
            receipts[index].resolution = "discarded"
            chat.saveReceipts = receipts
            if repo == chat.repo?.ref { workspace = nil } else { extraChangeWorkspaces[repo] = nil }
            changeSession = nil
            appendNotice(repo.isGitLab ? "Closed the merge request and removed its side branch." : "Closed the pull request and removed its side branch.")
        } catch { appendNotice("Couldn't throw it away: \(app.describe(error, for: repo))") }
    }

    func undoLastSave() async {
        guard let receipts = chat.saveReceipts,
              let index = receipts.lastIndex(where: { $0.undoneAt == nil }) else { return }
        if let problem = await undoSave(receipts[index].id) {
            appendNotice("Undo stopped safely: \(problem)")
        } else {
            appendNotice("Undid MAIPA-G's last save.")
        }
    }

    /// Undoes one save; nil when it worked, otherwise why not.
    private func undoSave(_ receiptID: UUID) async -> String? {
        guard let app, var receipts = chat.saveReceipts,
              let index = receipts.firstIndex(where: { $0.id == receiptID && $0.undoneAt == nil }) else { return "That save is no longer there." }
        let repo = receipts[index].repo
        guard let github = app.repoClient(for: repo) else { return "Connect \(repo.hostName) first." }
        do {
            let undoReceipt = try await GitHubChangeService(github: github).undo(receipts[index])
            receipts[index].undoneAt = Date()
            chat.saveReceipts = receipts
            if repo != chat.repo?.ref {
                // Another of the chat's repos: its copy reloads at the new commit next turn.
                if let existing = extraChangeWorkspaces[repo] {
                    extraChangeWorkspaces[repo] = await existing.rebased(onto: existing.base.advancing(toCommit: undoReceipt.savedCommit))
                }
            } else if let existingWorkspace = workspace {
                let advanced = existingWorkspace.advancing(toCommit: undoReceipt.savedCommit)
                workspace = advanced
                if let existingChanges = changeWorkspace {
                    changeWorkspace = await existingChanges.rebased(onto: advanced)
                }
            } else {
                workspace = nil
            }
            changeSession = nil
            return nil
        } catch { return app.describe(error, for: repo) }
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
        userStoppedExplicitly = false
        let grace = BackgroundGrace(name: "MAIPA-G reply") { [weak self] in
            // iOS is taking the app away. Save, but do not cancel the reply. A short trip
            // to the home screen used to kill the turn and every sub-agent.
            self?.saveSoon(immediately: true)
        }
        Task { [weak self] in
            await self?.runTurn()
            grace.end()
            await MainActor.run {
                guard let self,
                      !self.isRunning,
                      !self.pausedInBackground,
                      !self.queuedSteering.isEmpty,
                      self.lastTurn?.status != .waitingForUser else { return }
                let next = self.queuedSteering.removeFirst()
                self.syncQueuedFollowUpsToChat()
                self.send(next.text, attachments: next.attachments)
            }
        }
    }

    private func runTurn() async {
        let resumeNote = pendingResumeNote
        pendingResumeNote = nil
        defer {
            flush()
            // Every way out of here settles the turn. Early returns used to leave a new turn in
            // its default "running" state, so the card said "Thinking…" with nothing running.
            if var turn = lastTurn, turn.status == .running {
                turn.status = .stopped
                replaceLastTurn(turn)
            }
            refreshStagedChanges()
            isRunning = false
            run = nil
            saveSoon(immediately: true)
            if lastTurn?.status != .running {
                UserDefaults.standard.removeObject(forKey: Self.autoResumeKey(chat.id))
            }
            app?.turnFinished(in: self)
        }
        guard let app else { return }
        // Kiro checkpoint: the chat as it was before this message ran.
        await captureCheckpoint()
        guard app.openRouter.isSignedIn else {
            fail(.signInNeeded, "Connect an AI provider (OpenRouter, OneProvider, SayGM, TeamoRouter, or OmniRoute) in Settings first.")
            return
        }
        let setupDeadline = Date().addingTimeInterval(Self.setupTimeLimit)
        setupRanOut = false
        setupTimer = ReplySetupTimer()
        let connectors = app.connectors
        // Only a short wait: reconnecting goes on in the background, and a connector that comes
        // back is there for the next reply. Waiting for every broken connector first is how a
        // reply sat on "Thinking…" with nothing sent to the AI yet.
        let connectorDeadline = min(setupDeadline, Date().addingTimeInterval(ConnectorReconnectPolicy.replyWaitLimit))
        await setupStep(connectorDeadline, fallback: (), label: "reconnecting connectors", countsAsRanOut: false) { await connectors.reconnectIfNeeded() }
        let aiClient = app.openRouter.client
        let hasOpenRouter = app.openRouter.hasOpenRouterKey

        let lastMessage = chat.messages.last { $0.userText != nil }?.userText ?? ""
        if case .model(let pickedID) = chat.model,
           let pickedModel = app.openRouter.modelsByID[pickedID],
           pickedModel.isPureImageModel {
            await readBalanceBefore(modelID: pickedModel.id, app: app, deadline: setupDeadline)
            let lastUserMessage = chat.messages.last { $0.userText != nil }
            await runPureImageTurn(
                model: pickedModel,
                prompt: lastUserMessage?.userText ?? "",
                attachments: lastUserMessage?.userAttachments ?? [],
                client: aiClient,
                app: app
            )
            return
        }
        // The chat decides, like Kiro: only a message that is clearly asking for multi-step work
        // starts a workflow, and only when the Workflows switch is on. There is deliberately no
        // extra spending confirmation here — a workflow is sub-agents running longer, so it starts
        // the way they do, and the ordinary spend limit and stop-and-ask setting still apply.
        // A failed start falls through to answering normally rather than leaving the chat empty.
        // It runs here in the chat (executeChatWorkflow), so the Workflows switch alone is enough
        // and its progress and result show in this chat. Autonomous only governs Autonomous jobs.
        let routedWorkflow: WorkflowDefinition? = (resumeNote == nil && effectiveMode == .vibe && chat.repo != nil)
            ? app.jobs.routedWorkflow(request: lastMessage, repo: chat.repo)
            : nil
        var inChatWorkflowContext: (agents: [AgentDefinition], tools: [any AgentTool], repo: SystemPrompt.RepoContext?)?
        let changeAuthorization = ChangeAuthorization(request: lastMessage)
        let allAttachments = chat.messages.flatMap { message -> [AttachmentReference] in
            if case .user(let user) = message.body { return user.attachments }
            return []
        }
        var attachmentData: [UUID: Data] = [:]
        var skippedAttachments: [String] = []
        for attachment in allAttachments where attachment.kind == .image || attachment.kind == .pdf {
            guard attachment.bytes <= 32 * 1_048_576,
                  let raw = try? await app.attachmentStore.data(for: attachment) else {
                // Dropping a file silently made a too-big PDF look like it had been read.
                skippedAttachments.append(attachment.name)
                continue
            }
            if attachment.kind == .image, raw.count > 420_000 {
                attachmentData[attachment.id] = Self.compactWireImageData(raw)
            } else {
                attachmentData[attachment.id] = raw
            }
        }
        let memoryReloadHook: @Sendable () async -> Void = { [weak app] in
            await app?.memories.load()
            await MainActor.run { app?.sync.request() }
        }
        var tools: [any AgentTool] = webEnabled ? [WebSearchTool(transport: app.transport), ReadWebPageTool(transport: app.transport)] : []
        tools.append(contentsOf: app.connectors.agentTools())
        tools.append(AddMemoryTool(store: app.memories.store, onChanged: memoryReloadHook))
        tools.append(EditMemoryTool(store: app.memories.store, onChanged: memoryReloadHook))
        tools.append(LiveStatusTool { [weak self, weak app] in
            await MainActor.run {
                guard let app else { return "MAIPA-G is no longer open." }
                return app.liveStatusText(for: self)
            }
        })
        var readOnlyExtraTools: [any AgentTool] = []
        if let github = app.github.client {
            tools.append(CreateRepositoryTool(github: github))
        }
        if let github = app.github.client ?? app.gitlab.client.map({ lab -> GitHubClient in
            var client = GitHubClient(transport: app.transport, tokens: nil)
            client.gitLab = lab
            return client
        }) {
            // GitHub repos and GitLab projects alike; each is answered by its own service.
            let readOtherRepoTool = ReadOtherRepositoryFileTool(github: github, repositories: app.github.repos + app.gitlab.repos)
            tools.append(readOtherRepoTool)
            readOnlyExtraTools.append(readOtherRepoTool)
        }
        if !allAttachments.isEmpty {
            tools.append(ReadAttachmentTool(attachments: allAttachments, store: app.attachmentStore))
        }
        let listWorkstationProvider: @Sendable () async -> [WorkstationFileItem] = { [weak self] in
            await self?.collectWorkstationItems() ?? []
        }
        let readStagedTextProvider: @Sendable (String) async throws -> String? = { [weak self] stagedPath in
            guard let cw = await MainActor.run(body: { self?.changeWorkspace }) else { return nil }
            let staged = await cw.stagedChanges()
            guard case .write(_, let data, _) = staged.first(where: { $0.path == stagedPath }) else { return nil }
            return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        }
        let listWorkstationTool = ListWorkstationFilesTool(listProvider: listWorkstationProvider)
        let readWorkstationTool = ReadWorkstationFileTool(
            store: app.attachmentStore,
            listProvider: listWorkstationProvider,
            readStagedText: readStagedTextProvider
        )
        let writeWorkstationTool = WriteWorkstationFileTool(store: app.attachmentStore) { [weak self] reference, _ in
            await MainActor.run {
                guard let self else { return }
                self.workstationFiles.removeAll { $0.name.caseInsensitiveCompare(reference.name) == .orderedSame }
                self.workstationFiles.insert(reference, at: 0)
            }
        }
        let workstationTools: [any AgentTool] = [listWorkstationTool, readWorkstationTool, writeWorkstationTool]
        tools.append(contentsOf: workstationTools)
        var readOnlyHelperTools: [any AgentTool] = webEnabled ? [WebSearchTool(transport: app.transport), ReadWebPageTool(transport: app.transport)] : []
        let readOnlyWorkstationTools: [any AgentTool] = [listWorkstationTool, readWorkstationTool]
        readOnlyHelperTools.append(contentsOf: readOnlyWorkstationTools)
        readOnlyHelperTools.append(contentsOf: readOnlyExtraTools)
        readOnlyHelperTools.append(LiveStatusTool { [weak self, weak app] in
            await MainActor.run { app?.liveStatusText(for: self) ?? "MAIPA-G is no longer open." }
        })
        if !allAttachments.isEmpty {
            readOnlyHelperTools.append(ReadAttachmentTool(attachments: allAttachments, store: app.attachmentStore))
        }
        var repoContext: SystemPrompt.RepoContext?
        var repoHooks: [RepoHook] = []
        var hookProblems: [String] = []
        var repoLocalAgents: [AgentDefinition] = []
        if let repo = chat.repo {
            guard let github = app.repoClient(for: repo.ref) else {
                fail(.signInNeeded, "Connect \(repo.ref.hostName) so MAIPA-G can read \(repo.ref.fullName).")
                return
            }
            do {
                var activeReceipt = (chat.saveReceipts ?? []).last { $0.repo == repo.ref && $0.pullRequest != nil && $0.resolution == nil }
                // Opening the repo counts against the same getting-ready limit as everything else.
                // These steps used to wait on GitHub with no limit at all, after the connectors
                // and the computer had been given theirs, so a slow GitHub (or staged changes being
                // carried onto a branch that had moved) held the reply on "Thinking…" with no
                // request sent to the AI yet. Rules, hooks and the diff get at least 30 seconds.
                let repoDeadline = max(setupDeadline, Date().addingTimeInterval(30))
                if let candidate = activeReceipt, let pull = candidate.pullRequest {
                    let ref = repo.ref, number = pull.number
                    let current: GitHubPullRequest? = await setupStep(repoDeadline, fallback: nil, label: "checking the pull request") { try? await github.pullRequest(ref, number: number) }
                    if let current, current.state != "open" {
                        if var receipts = chat.saveReceipts, let idx = receipts.firstIndex(where: { $0.id == candidate.id }) {
                            receipts[idx].resolution = "closed"
                            chat.saveReceipts = receipts
                        }
                        changeSession = nil
                        activeReceipt = nil
                    }
                }
                let workingBranch = activeReceipt?.branch ?? repo.branch
                let workingRepo = ChatRepo(ref: repo.ref, branch: workingBranch, defaultBranch: repo.defaultBranch, isPrivate: repo.isPrivate)
                let commitRef = repo.ref
                let commit = try await AgentLoop.bounded(seconds: max(repoDeadline.timeIntervalSinceNow, 30), label: "Opening \(repo.ref.fullName) on \(repo.ref.hostName)") {
                    try await github.resolveCommit(commitRef, ref: workingBranch)
                }
                let workspace = workspaceFor(repo: workingRepo, commit: commit, github: github, store: app.snapshots)
                await setupStep(setupDeadline, fallback: (), label: "reading the repo") { await workspace.prefetch() }
                let changes: ChangeWorkspace
                if let existing = changeWorkspace {
                    if existing.base.commit == commit && existing.base.repo == workspace.repo {
                        changes = existing
                    } else if existing.base.repo == workspace.repo {
                        // Carrying staged edits onto the moved branch reads each file again; if
                        // that can't finish in time, keep them on the commit they were made on.
                        let rebased = await setupStep(repoDeadline, fallback: existing, label: "updating staged changes") { await existing.rebased(onto: workspace) }
                        changes = rebased
                        changeWorkspace = rebased
                    } else {
                        changes = ChangeWorkspace(base: workspace)
                        changeWorkspace = changes
                    }
                } else {
                    changes = ChangeWorkspace(base: workspace)
                    changeWorkspace = changes
                }
                if let restore = pendingStagedRestore {
                    await changes.restoreStaged(restore)
                    pendingStagedRestore = nil
                }
                let service = GitHubChangeService(github: github)
                let directSaveSetting = app.settings.savesDirectly(to: repo.ref)
                // Rules that couldn't be read in time never mean saving straight to the branch.
                let rules = await setupStep(repoDeadline, fallback: RepoWriteRules(directSave: false, reason: "The repo's rules couldn't be read in time, so changes save as a pull request."), label: "reading the repo's rules") {
                    await service.resolveRules(in: workspace, directSaveSetting: directSaveSetting, requestText: lastMessage)
                }
                let loadedHooks = await setupStep(repoDeadline, fallback: (hooks: [RepoHook](), problems: [String]()), label: "reading repo hooks") { await RepoHooks.load(from: workspace) }
                repoHooks = loadedHooks.hooks
                hookProblems = loadedHooks.problems
                repoLocalAgents = await setupStep(repoDeadline, fallback: [], label: "reading repo agents") { await RepoAgentLoader.loadAgents(from: workspace) }
                let saves = changeSession ?? ChangeSession(receipts: chat.saveReceipts ?? [])
                changeSession = saves
                let listTool = ListFilesTool(workspace: workspace, changes: changes)
                let searchTool = SearchCodeTool(workspace: workspace, changes: changes)
                let readTool = ReadFileTool(workspace: workspace, changes: changes)
                let readRefTool = ReadRepoFileTool(github: github)
                let loadRulesTool = LoadRepoRulesTool(documents: rules.documents)
                let helperRepoTools: [any AgentTool] = [listTool, searchTool, readTool, readRefTool, loadRulesTool]
                readOnlyHelperTools.append(contentsOf: helperRepoTools)
                let repoTools: [any AgentTool] = [
                    listTool, searchTool, readTool, readRefTool, loadRulesTool,
                    CreateFileTool(workspace: changes, authorization: changeAuthorization, rules: rules),
                    EditFileTool(workspace: changes, authorization: changeAuthorization, rules: rules),
                    AppendFileTool(workspace: changes, authorization: changeAuthorization, rules: rules),
                    DeleteFileTool(workspace: changes, authorization: changeAuthorization, rules: rules),
                    SaveChangesTool(workspace: changes, service: service, session: saves, selectedBranch: workingBranch, defaultBranch: repo.defaultBranch, rules: rules),
                ]
                // The chat's other repos: the same tools for each, chosen with a repo argument.
                var perRepo: [(repo: String, tools: [any AgentTool])] = [(repo.ref.fullName, repoTools)]
                var perRepoHelpers: [(repo: String, tools: [any AgentTool])] = [(repo.ref.fullName, helperRepoTools)]
                for extra in chat.allRepos.dropFirst() {
                    do {
                        let set = try await extraRepoTools(extra, app: app, saves: saves, authorization: changeAuthorization, lastMessage: lastMessage, setupDeadline: setupDeadline)
                        perRepo.append((extra.ref.fullName, set.tools))
                        perRepoHelpers.append((extra.ref.fullName, set.helpers))
                    } catch let error as MissingConnection {
                        fail(.signInNeeded, error.message)
                        return
                    } catch {
                        fail(.other, "Couldn't open \(extra.ref.fullName) on \(extra.ref.hostName). \(app.describe(error, for: extra.ref))")
                        return
                    }
                }
                if perRepo.count > 1 {
                    let names = Set(repoTools.map(\.name))
                    readOnlyHelperTools.removeAll { names.contains($0.name) }
                    readOnlyHelperTools.append(contentsOf: RepoRoutedTool.combine(perRepoHelpers))
                    tools.append(contentsOf: RepoRoutedTool.combine(perRepo))
                } else {
                    tools.append(contentsOf: repoTools)
                }
                repoContext = SystemPrompt.RepoContext(
                    ref: repo.ref,
                    branch: workingBranch,
                    commit: commit,
                    isPrivate: repo.isPrivate,
                    summary: app.knownRepo(repo.ref)?.summary,
                    ruleDocuments: rules.documents
                )
            } catch {
                fail(.other, "Couldn't open \(repo.ref.fullName) on \(repo.ref.hostName). \(app.describe(error, for: repo.ref))")
                return
            }
        }
        let prewarmRepo = repoContext
        let prewarmAutonomous = autonomous && app.settings.autonomousEnabled
        let computerNote: String? = await setupStep(setupDeadline, fallback: nil, label: "starting the computer") {
            await self.prepareComputer(app: app, repo: prewarmRepo, lastUserMessage: lastMessage, isAutonomous: prewarmAutonomous)
        }
        var canSyncStaged = false
        if let repoContext, let workspace = changeWorkspace, let control = app.connectors.computerControl(), control.commandTool != nil, app.openRouter.supportsTools(chat.model) {
            tools.append(SyncStagedToComputerTool(
                control: control, workspace: workspace,
                homePath: "repos/\(repoContext.ref.owner)/\(repoContext.ref.name)",
                cloneURL: repoContext.isPrivate ? nil : repoContext.ref.webURL.absoluteString + ".git",
                commit: repoContext.commit
            ))
            canSyncStaged = true
        }
        // Hooks from the repo's .kiro/hooks run after the tools they listen to. Command hooks run
        // on the chat computer, in the repo's copy, after the staged files are put there.
        var hookRunner: HookedTool.CommandRunner?
        if let repoContext, let workspace = changeWorkspace, let control = app.connectors.computerControl(), control.commandTool != nil {
            let homePath = "repos/\(repoContext.ref.owner)/\(repoContext.ref.name)"
            let cloneURL: String? = repoContext.isPrivate ? nil : repoContext.ref.webURL.absoluteString + ".git"
            let commit = repoContext.commit
            hookRunner = { command in
                _ = try await control.syncStagedChanges(homePath: homePath, cloneURL: cloneURL, commit: commit, changes: await workspace.stagedChanges())
                return try await control.run("cd \"$HOME/\(homePath)\" && \(command)")
            }
        }
        // Attach the shell, reconnecting first if the session dropped. It used to be skipped
        // silently whenever no live session existed, so one failed restore cost the whole turn its
        // computer while the machine was running the entire time, with nothing said.
        if app.openRouter.supportsTools(chat.model), app.connectors.hasConfiguredComputer {
            if let control = await setupStep(setupDeadline, fallback: nil, label: "connecting the computer", { await connectors.ensureComputerSession() }), control.commandTool != nil {
                let repoHome = repoContext.map { "repos/\($0.ref.owner)/\($0.ref.name)" }
                tools.append(RunCommandTool(control: control, homePath: repoHome))
                tools.append(ComputerTaskTool(control: control, homePath: repoHome))
            } else if var turn = lastTurn {
                // Say it out loud. A missing computer must never look like work that simply failed.
                turn.notices.append("The chat computer is configured but couldn't be reached, so commands can't run in this reply. The machine itself may still be on.")
                replaceLastTurn(turn)
            }
        }
        tools = HookedTool.wrap(tools, hooks: repoHooks, runCommand: hookRunner)
        // Kiro specs: three files under .kiro/specs/<feature>/ in the chat's repo, read with
        // load_spec (Kiro's #spec), with Spec mode's approval gates enforced on the file tools.
        var existingSpecs: [String] = []
        var inlineRepoText = ""
        let approvedByButton = specApprovedByButton
        specApprovedByButton = false
        if repoContext != nil, let specChanges = changeWorkspace {
            let readSpecFile: LoadSpecTool.Reader = { path in
                guard case .text(let text, _) = try? await specChanges.read(path) else { return nil }
                return text
            }
            let listRepoFiles: LoadSpecTool.Lister = {
                ((try? await specChanges.mergedTree())?.entries ?? []).filter(\.isFile).map(\.path)
            }
            tools.append(LoadSpecTool(read: readSpecFile, list: listRepoFiles))
            let references = KiroContextReferences.parse(lastMessage)
            let kind = specKind
            if effectiveMode == .spec {
                existingSpecs = await setupStep(setupDeadline, fallback: [], label: "listing specs") { KiroSpecs.slugs(in: await listRepoFiles()) }
                if let state = chat.kiroSpec {
                    // An approval reply moves the spec on one phase, once that phase's document
                    // exists. The approve button has already done it for its own message.
                    if !approvedByButton {
                        let documentExists: Bool
                        if let path = state.path(state.phase) { documentExists = await readSpecFile(path) != nil } else { documentExists = true }
                        let next = KiroSpecs.afterMessage(lastMessage, state: state, currentDocumentExists: documentExists)
                        if next != state { chat.kiroSpec = next; touch() }
                    }
                } else if let named = references.specs.first(where: KiroSpecs.isValidSlug) {
                    // `#spec:<name>` in Spec mode picks up a spec already in the repo where it left off.
                    let base = KiroSpecs.folder + named + "/"
                    let hasRequirements = await readSpecFile(base + "requirements.md") != nil
                    let hasBugfix = await readSpecFile(base + "bugfix.md") != nil
                    let hasDesign = await readSpecFile(base + "design.md") != nil
                    let hasTasks = await readSpecFile(base + "tasks.md") != nil
                    if hasRequirements || hasBugfix || hasDesign || hasTasks {
                        chat.kiroSpec = KiroSpecs.resume(slug: named, hasRequirements: hasRequirements, hasDesign: hasDesign, hasTasks: hasTasks, hasBugfix: hasBugfix)
                        touch()
                    }
                }
                let gateState = chat.kiroSpec
                tools = KiroSpecGatedTool.wrap(tools, kind: kind, state: { gateState })
            }
            // Kiro puts steering and the spec into every message (owner decision, 11 November 2026):
            // always files, fileMatch files for the files in play, manual ones named with #, the
            // files they reference with #[[file:]], and this chat's spec. Marked as repo text, size-limited.
            let stagedPaths = await specChanges.stagedChanges().map(\.path)
            let inPlay = stagedPaths + references.files + KiroInlineContext.mentionedPaths(in: lastMessage)
            let steering = KiroInlineContext.steeringItems(repoContext?.ruleDocuments ?? [], paths: inPlay, referencedNames: Set(references.steering))
            var items = steering
            var followed = 0
            for item in steering {
                for reference in KiroInlineContext.fileReferences(in: item.text) where followed < KiroInlineContext.maxFileReferences {
                    followed += 1
                    if let text = await readSpecFile(reference) {
                        items.append(KiroInlineContext.Item(path: reference, text: text, reason: "referenced from \(item.path)"))
                    }
                }
            }
            var specSlugs: [String] = []
            if effectiveMode == .spec, let state = chat.kiroSpec { specSlugs.append(state.slug) }
            for named in references.specs where KiroSpecs.isValidSlug(named) && !specSlugs.contains(named) { specSlugs.append(named) }
            for slug in specSlugs.prefix(3) {
                for document in KiroSpecs.documents {
                    let path = KiroSpecs.folder + slug + "/" + document
                    if let text = await readSpecFile(path) {
                        items.append(KiroInlineContext.Item(path: path, text: text, reason: slug == chat.kiroSpec?.slug ? "this chat's spec" : "referenced with #spec:\(slug)"))
                    }
                }
            }
            inlineRepoText = KiroInlineContext.section(items)
        }
        // Supervised (Kiro's permission mode): nothing is saved until the person has reviewed it.
        if permissionMode == .supervised {
            tools = SupervisedSaveGate.wrap(tools, unreviewed: { [weak self] in await self?.unreviewedPaths() ?? [] })
        }
        for problem in hookProblems {
            _ = app.report(RepoHookProblem(message: problem), area: "hooks", operation: "read repo hooks")
        }
        // Building the staged diff reads each changed file's original from GitHub, so it has a
        // limit too; without one the Review Changes state alone could hold the reply up.
        let diffDeadline = max(setupDeadline, Date().addingTimeInterval(30))
        let diffUnavailable = "Staged changes exist, but their diff couldn't be built in time. Use read_file to see the staged files."
        var stagedPatch: String?
        if let primary = changeWorkspace {
            stagedPatch = await setupStep(diffDeadline, fallback: diffUnavailable, label: "building the staged diff") { await primary.stagedDiffForPrompt() }
        }
        for extra in allChangeWorkspaces.dropFirst() {
            guard await extra.hasStagedChanges() else { continue }
            let patch = await setupStep(diffDeadline, fallback: diffUnavailable, label: "building the staged diff") { await extra.stagedDiffForPrompt() }
            stagedPatch = (stagedPatch.map { $0 + "\n\n" } ?? "") + "Staged in \(extra.base.repo.fullName):\n" + patch
        }
        let contextRepo = repoContext
        let allStagedPatches = stagedPatch
        var computer: SystemPrompt.ComputerContext? = await setupStep(setupDeadline, fallback: nil, label: "reading the computer") {
            await self.computerContext(app: app, repo: contextRepo, stagedPatch: allStagedPatches)
        }
        computer?.appNote = computerNote
        computer?.canSyncStaged = canSyncStaged

        let hasRepo = chat.repo != nil
        var difficulty = TaskDifficulty.estimate(lastMessage, hasRepo: hasRepo)
        if chat.model == .auto, app.openRouter.accountState.paidAllowed(),
           let judged = await setupStep(setupDeadline, fallback: nil, label: "judging the request", { await OnDeviceAI.difficulty(of: lastMessage, hasRepo: hasRepo) }) {
            difficulty = judged
        }
        let catalogue = app.openRouter.modelsByID
        let lastUserAttachments: [AttachmentReference] = {
            for message in chat.messages.reversed() {
                if case .user(let user) = message.body { return user.attachments }
            }
            return []
        }()
        if case .model(let modelID) = chat.model,
           let model = catalogue[modelID],
           lastUserAttachments.contains(where: { $0.kind == .image }) && !model.acceptsImages {
            fail(.other, "This AI can't read pictures. Pick Auto or a vision AI that accepts pictures.")
            return
        }
        let thinking = chat.thinking
        let judgedDifficulty = difficulty
        let hasImageInput = allAttachments.contains { $0.kind == .image }
        let route = ModelRouter.route(
            choice: chat.model,
            difficulty: judgedDifficulty,
            thinking: thinking,
            account: app.openRouter.accountState,
            catalogue: catalogue,
            requiresImageInput: hasImageInput,
            openRouterAvailable: hasOpenRouter
        )
        let imagePool = app.openRouter.allSelectableModels.isEmpty ? app.openRouter.models : app.openRouter.allSelectableModels
        let preferredImageModel: ModelInfo? = {
            if let current = catalogue[route.model], current.generatesImages { return current }
            return imagePool.first(where: \.generatesImages)
        }()
        if let imageModel = preferredImageModel {
            // Pictures in the chat can be named as input when the picture model takes images.
            tools.append(GenerateImageTool(client: aiClient, store: app.attachmentStore, model: imageModel.id, maySpend: !imageModel.isFree, availableImages: chatPictures()))
        }
        let isExternalRoute = AIProviderModelID.decode(route.model) != nil
        let isExplicitPick: Bool = {
            if case .model = chat.model { return true }
            return false
        }()
        let fallbackModels = (isExternalRoute || isExplicitPick) ? [] : app.openRouter.models.filter { model in
            AIProviderModelID.decode(model.id) == nil
                && model.id != route.model && model.isChatModel
                && (!hasRepo || model.supportsTools)
                && (!hasImageInput || model.acceptsImages)
                && (!route.isFree || model.isFree)
        }.prefix(ChatCompletionRequest.maxModels - 1).map(\.id)
        let isAutonomousTurn = autonomous && app.settings.autonomousEnabled
        let userChoice = chat.model
        let accountState = app.openRouter.accountState
        let userLogin = app.github.login
        let connectedRepoNames = app.github.repos.map(\.fullName)

        let createCustomAgentTool = CreateCustomAgentTool { [weak app] draft in
            guard let app else { return draft }
            let saved = await app.automations.saveAgent(CustomAgentRecord(
                name: draft.name,
                summary: draft.summary,
                instructions: draft.instructions,
                allowedTools: draft.allowedTools,
                difficulty: draft.difficulty,
                modelPolicy: draft.modelPolicy,
                behavior: draft.behavior,
                maximumHelpers: draft.maximumHelpers
            ))
            return await MainActor.run { saved?.definition ?? draft }
        }
        tools.append(createCustomAgentTool)

        let turnSteering = SteeringInbox()
        if app.openRouter.supportsTools(chat.model) {
            let builtInHelpers = BuiltInAgents.kiroSubagents + BuiltInAgents.all.filter {
                ["planner", "designer", "design-checker", "design-reviewer", "code-checker", "second-opinion", "review-combiner", "investigator"].contains($0.id)
            }
            var seenHelperIDs = Set<String>()
            var builtHelpers: [AgentDefinition] = []
            for candidate in builtInHelpers + repoLocalAgents + app.automations.customAgents.map(\.definition) {
                if seenHelperIDs.insert(candidate.id).inserted {
                    builtHelpers.append(candidate)
                }
            }
            let helperDefinitions = builtHelpers
            if let baseLead = BuiltInAgents.named("coder"), !helperDefinitions.isEmpty {
                var lead = baseLead
                lead.maximumHelpers = max(lead.maximumHelpers, 16)
                let inspectWorkflowTool = InspectWorkflowTool { [weak self, weak app] query in
                    await MainActor.run {
                        guard let self else { return "Chat closed." }
                        return self.inspectWorkflowsReport(query: query, app: app)
                    }
                }
                var extraHelperTools: [any AgentTool] = readOnlyHelperTools
                extraHelperTools.append(inspectWorkflowTool)
                extraHelperTools.append(createCustomAgentTool)
                let helperToolsSnapshot = extraHelperTools
                var allHelperTools: [any AgentTool] = tools
                allHelperTools.append(inspectWorkflowTool)
                let fullToolsSnapshot = allHelperTools
                let repoContextSnapshot = repoContext
                let primaryModelID = route.model
                let coordinator = AgentHelperCoordinator(
                    lead: lead,
                    definitions: helperDefinitions,
                    context: lastMessage,
                    spendLimit: app.settings.spendLimitOn ? app.settings.spendLimit : nil,
                    steering: turnSteering
                ) { invocation in
                    var helperChoice = userChoice
                    if let explicitModel = invocation.preferredModelID, !explicitModel.isEmpty, explicitModel != ModelChoice.freeID {
                        helperChoice = .model(explicitModel)
                    } else if invocation.definition.modelPolicy == .differentFromPrimary {
                        if let alt = catalogue.values.first(where: { (hasOpenRouter || AIProviderModelID.decode($0.id) != nil) && $0.id != primaryModelID && $0.isChatModel && $0.supportsTools && (!route.isFree || $0.isFree) }) {
                            helperChoice = .model(alt.id)
                        }
                    }
                    let helperThinking = invocation.preferredEffort ?? thinking
                    let helperRoute = ModelRouter.route(
                        choice: helperChoice,
                        difficulty: invocation.definition.difficulty,
                        thinking: helperThinking,
                        account: accountState,
                        catalogue: catalogue,
                        requiresImageInput: false,
                        openRouterAvailable: hasOpenRouter
                    )
                    var helperChat = Chat(model: helperChoice, thinking: helperThinking)
                    helperChat.messages.append(.user(invocation.task))
                    helperChat.messages.append(ChatMessage(body: .assistant(AssistantTurn())))
                    let helperPrompt = SystemPrompt.make(
                        userLogin: userLogin,
                        repo: repoContextSnapshot,
                        agent: invocation.definition,
                        workflowContext: invocation.context,
                        connectedRepositories: connectedRepoNames
                    )
                    let basePool = invocation.definition.behavior == .changesAllowed ? fullToolsSnapshot : helperToolsSnapshot
                    let allowedPool = basePool.filter { invocation.definition.permits(tool: $0.name) }
                    let helperInput = AgentTurnInput(
                        chat: helperChat,
                        route: helperRoute,
                        systemPrompt: helperPrompt,
                        tools: allowedPool,
                        allowTools: true,
                        maxSteps: 400,
                        spendLimit: invocation.spendLimit,
                        requiresInitialSpendApproval: false,
                        agent: invocation.definition,
                        allowAskUser: false
                    )
                    let helperEnv = AgentEnvironment(
                        openRouter: aiClient,
                        freeRoute: {
                            ModelRouter.route(choice: .free, difficulty: .normal, thinking: .default, account: AccountState(), catalogue: catalogue, openRouterAvailable: hasOpenRouter)
                        },
                        onOutOfCredits: {}
                    )
                    invocation.onLiveProgress?(AgentLiveProgress(
                        model: helperRoute.model,
                        toolCallCount: 0,
                        latestActivity: "Starting…"
                    ))
                    let helperRun = AgentLoop.start(helperInput, environment: helperEnv)
                    var finalTurn: AssistantTurn?
                    var lastLiveSignature = ""
                    do {
                        for await event in helperRun.events {
                            try Task.checkCancellation()
                            if case .updated(let updated, _) = event {
                                finalTurn = updated
                                let calls = updated.steps.flatMap(\.toolCalls)
                                let completedCalls = calls.filter { $0.status == .done || $0.status == .failed }.count
                                let summaries = calls.map(\.summary)
                                let runningToolSummary = calls.last(where: { $0.status == .running })?.summary
                                let latestReasoning = updated.steps.reversed().compactMap { $0.reasoning.isEmpty ? nil : $0.reasoning }.first
                                let liveThought = latestReasoning.map { String($0.suffix(900)) }
                                let partialOutput = updated.steps.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n\n")
                                let latestNotice = updated.notices.last
                                let actionSuffix = completedCalls > 0 ? " (\(completedCalls) done)" : ""
                                let latestActivity: String = {
                                    if let runningToolSummary, !runningToolSummary.isEmpty { return runningToolSummary }
                                    if let latestNotice, latestNotice.localizedCaseInsensitiveContains("retry") || latestNotice.localizedCaseInsensitiveContains("wait") {
                                        return latestNotice
                                    }
                                    if !partialOutput.isEmpty { return "Writing findings…\(actionSuffix)" }
                                    if liveThought != nil { return "Thinking…\(actionSuffix)" }
                                    return summaries.last ?? "Working…"
                                }()
                                let signature = "\(calls.count)|\(completedCalls)|\(latestActivity)|\(partialOutput.count)|\(latestReasoning?.count ?? 0)|\(latestNotice ?? "")"
                                if signature != lastLiveSignature {
                                    lastLiveSignature = signature
                                    invocation.onLiveProgress?(AgentLiveProgress(
                                        model: updated.modelsUsed.last ?? helperRoute.model,
                                        toolCallCount: calls.count,
                                        latestActivity: latestActivity,
                                        toolSummaries: summaries,
                                        liveThought: liveThought,
                                        partialOutput: partialOutput
                                    ))
                                }
                            }
                        }
                    } catch is CancellationError {
                        helperRun.cancel()
                        let calls = finalTurn?.steps.flatMap(\.toolCalls) ?? []
                        let partial = finalTurn?.steps.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n\n") ?? ""
                        return AgentExecutionResult(
                            output: partial.isEmpty ? "cancelled" : partial,
                            model: finalTurn?.modelsUsed.last ?? helperRoute.model,
                            cost: finalTurn?.usage.cost ?? 0,
                            toolCallCount: calls.count,
                            toolSummaries: calls.map(\.summary),
                            status: "cancelled"
                        )
                    }
                    if Task.isCancelled {
                        helperRun.cancel()
                        let calls = finalTurn?.steps.flatMap(\.toolCalls) ?? []
                        let partial = finalTurn?.steps.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n\n") ?? ""
                        return AgentExecutionResult(
                            output: partial.isEmpty ? "cancelled" : partial,
                            model: finalTurn?.modelsUsed.last ?? helperRoute.model,
                            cost: finalTurn?.usage.cost ?? 0,
                            toolCallCount: calls.count,
                            toolSummaries: calls.map(\.summary),
                            status: "cancelled"
                        )
                    }
                    let allCalls = finalTurn?.steps.flatMap(\.toolCalls) ?? []
                    let joinedText = finalTurn?.steps.map(\.text)
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                        .joined(separator: "\n\n") ?? ""
                    let fallbackReasoning = finalTurn?.steps.reversed()
                        .map { $0.reasoning.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .first(where: { !$0.isEmpty })
                    let cost = finalTurn?.usage.cost ?? 0
                    let modelUsed = finalTurn?.modelsUsed.last ?? helperRoute.model
                    if finalTurn?.status == .failed {
                        let failureMessage = finalTurn?.failure?.message ?? "Sub-agent failed."
                        let outputText = joinedText.isEmpty ? failureMessage : "\(joinedText)\n\nError: \(failureMessage)"
                        return AgentExecutionResult(
                            output: outputText,
                            model: modelUsed,
                            cost: cost,
                            toolCallCount: allCalls.count,
                            toolSummaries: allCalls.map(\.summary),
                            status: "failed"
                        )
                    }
                    if finalTurn?.status == .stopped, finalTurn?.failure?.kind != .stepLimit {
                        return AgentExecutionResult(
                            output: joinedText.isEmpty ? "cancelled" : joinedText,
                            model: modelUsed,
                            cost: cost,
                            toolCallCount: allCalls.count,
                            toolSummaries: allCalls.map(\.summary),
                            status: "cancelled"
                        )
                    }
                    let finalText: String
                    if !joinedText.isEmpty {
                        finalText = joinedText
                    } else if let fallbackReasoning {
                        finalText = fallbackReasoning
                    } else {
                        let word = allCalls.count == 1 ? "action" : "actions"
                        finalText = "Completed \(allCalls.count) \(word)."
                    }
                    if let pending = finalTurn?.pendingQuestions?.questions.questions.first {
                        // Only reachable for a turn that genuinely can ask. Reported as stopped
                        // rather than failed: nothing is broken and nothing ran — it is waiting.
                        return AgentExecutionResult(
                            output: "This sub-agent stopped because it needs a person's approval to continue: \(pending.text)",
                            model: modelUsed,
                            cost: cost,
                            pendingQuestion: AgentExecutionQuestion(text: pending.text, options: pending.options),
                            toolCallCount: allCalls.count,
                            toolSummaries: allCalls.map(\.summary),
                            status: "stopped"
                        )
                    }
                    return AgentExecutionResult(
                        output: finalText,
                        model: modelUsed,
                        goalOutcome: AgentGoalOutcome.parse(finalText),
                        cost: cost,
                        toolCallCount: allCalls.count,
                        toolSummaries: allCalls.map(\.summary),
                        status: "completed"
                    )
                }
                tools.append(LaunchHelpersTool(lead: lead, definitions: helperDefinitions, coordinator: coordinator))

                let knownAgentIDsProvider: @Sendable () async -> Set<String> = { [weak app] in
                    let custom = await MainActor.run { app?.automations.agents.map(\.id) ?? [] }
                    return Set(helperDefinitions.map(\.id) + BuiltInAgents.allIncludingKiroSubagents.map(\.id) + custom)
                }
                let workflowToolsSnapshot = tools + [inspectWorkflowTool]
                tools.append(SaveWorkflowDefinitionTool(knownAgentIDs: knownAgentIDsProvider) { [weak app] draft in
                    guard let app else { return draft }
                    let saved = await app.automations.saveWorkflow(WorkflowRecord(definition: draft))
                    return await MainActor.run { saved?.definition ?? draft }
                })
                // Workflows off means nothing can start a workflow from anywhere, the chat included.
                if app.settings.workflowsEnabled {
                inChatWorkflowContext = (helperDefinitions, workflowToolsSnapshot, repoContextSnapshot)
                tools.append(RunWorkflowTool(
                    resolveWorkflow: { [weak app] id in
                        await MainActor.run {
                            app?.automations.workflows.first(where: { $0.id == id || $0.name.caseInsensitiveCompare(id) == .orderedSame })
                        }
                    },
                    knownAgentIDs: knownAgentIDsProvider,
                    executeHandler: { [weak self] definition, prompt, progress in
                        guard let self else {
                            return ActiveWorkflowRunSnapshot(id: definition.id, definition: definition, checkpoint: WorkflowCheckpoint(workflowID: definition.id, request: prompt), isRunning: false)
                        }
                        return await self.executeChatWorkflow(
                            definition: definition,
                            prompt: prompt,
                            defaultModelID: route.model,
                            allAgents: helperDefinitions,
                            toolPool: workflowToolsSnapshot,
                            repoContext: repoContextSnapshot,
                            progress: progress
                        )
                    }
                ))
                }
                tools.append(inspectWorkflowTool)
                tools.append(UpdateWorkflowTool { [weak self] runID, replacementSteps in
                    guard let self else { throw ToolInputError("Chat is no longer open.") }
                    return try await self.replaceRemainingWorkflowSteps(runID: runID, steps: replacementSteps)
                })
            }
        }

        await readBalanceBefore(modelID: route.model, app: app, deadline: setupDeadline)
        if setupRanOut, var turn = lastTurn {
            turn.notices.append(Self.setupRanOutNotice)
            replaceLastTurn(turn)
        }
        // Where a slow start's time went, so it is never mistaken for a slow AI.
        if let notice = setupTimer.notice(), var turn = lastTurn {
            turn.notices.removeAll { $0.hasPrefix("Getting ready took ") && $0 != Self.setupRanOutNotice }
            turn.notices.append(notice)
            replaceLastTurn(turn)
        }
        // Stop pressed while getting ready: there is no run to cancel yet, so honour it here.
        if userStoppedExplicitly { return }
        if let workflow = routedWorkflow, let context = inChatWorkflowContext {
            await runRoutedWorkflow(workflow, request: lastMessage, defaultModelID: route.model, agents: context.agents, toolPool: context.tools, repoContext: context.repo)
            return
        }
        let routeModelInfo = catalogue[route.model]
        let activeModelSummary = SystemPrompt.ActiveModelSummary(
            modelName: app.openRouter.displayName(forModelID: route.model),
            modelID: route.model,
            providerName: app.openRouter.providerName(forModelID: route.model),
            effort: route.effort?.rawValue ?? chat.thinking.rawValue,
            contextLength: routeModelInfo?.contextLength ?? route.contextBudget,
            maxOutputTokens: routeModelInfo?.maxCompletionTokens ?? route.maxOutputTokens ?? 16_384,
            supportsVision: routeModelInfo?.acceptsImages ?? true,
            supportsPDF: true,
            generatesImages: routeModelInfo?.generatesImages ?? false,
            supportsTools: app.openRouter.supportsTools(chat.model)
        )
        let input = AgentTurnInput(
            chat: chat,
            route: route,
            systemPrompt: SystemPrompt.make(
                userLogin: app.github.login,
                repo: repoContext,
                computer: computer,
                activeModel: activeModelSummary,
                memories: chat.memoryContext,
                connectedRepositories: app.github.repos.map(\.fullName),
                isAutonomous: isAutonomousTurn,
                skippedAttachments: skippedAttachments
            ) + specModeSection(hasRepo: repoContext != nil, existingSpecs: existingSpecs)
              + (permissionMode == .supervised ? Self.supervisedInstructions : "")
              + KiroContextReferences.parse(lastMessage).promptSection
              + inlineRepoText,
            tools: tools,
            allowTools: app.openRouter.supportsTools(chat.model),
            spendLimit: app.settings.spendLimitOn ? app.settings.spendLimit : nil,
            attachmentData: attachmentData,
            serverTools: [],
            fallbackModels: fallbackModels,
            requiresInitialSpendApproval: false,
            steering: turnSteering,
            resumeNote: resumeNote
        )
        let account = app.openRouter
        let attachmentStore = app.attachmentStore
        var environment = AgentEnvironment(
            openRouter: aiClient,
            freeRoute: {
                ModelRouter.route(choice: .free, difficulty: judgedDifficulty, thinking: thinking, account: AccountState(), catalogue: catalogue, requiresImageInput: hasImageInput, openRouterAvailable: hasOpenRouter)
            },
            onOutOfCredits: { await account.markOutOfCredits() },
            saveInlineGeneratedImage: { data, mimeType, prompt, modelID in
                let ext = mimeType.contains("jpeg") || mimeType.contains("jpg") ? "jpg" : (mimeType.contains("webp") ? "webp" : "png")
                guard let ref = try? await attachmentStore.importGeneratedImage(data, name: "picture-\(UUID().uuidString.lowercased()).\(ext)", mimeType: mimeType) else {
                    return nil
                }
                let result = GeneratedImageResult(attachment: ref, prompt: prompt, model: modelID, aspectRatio: ImageAspectRatio.square.rawValue, quality: ImageQuality.standard.rawValue, cost: nil)
                try? await attachmentStore.saveGeneratedMetadata(result)
                return result
            }
        )
        environment.onModelRestricted = { model in await account.markRestricted(model) }

        let run = AgentLoop.start(input, environment: environment)
        self.run = run
        if !pendingSteers.isEmpty {
            let earlySteers = pendingSteers.map(\.text)
            for steerMsg in earlySteers {
                await run.steer(steerMsg)
            }
        }
        for await event in run.events {
            guard case .updated(let turn, let milestone) = event else { continue }
            receive(turn, milestone: milestone)
        }
        flush()
        // `KiroCrew#20549`: If a live steer arrived right as the turn finished without another step boundary,
        // promote it immediately so the model answers it instead of stranding it!
        if !userStoppedExplicitly, !pausedInBackground {
            let unconsumed = await run.drainUnconsumedSteering()
            if !unconsumed.isEmpty {
                queuedSteering.insert(QueuedFollowUp(text: unconsumed.joined(separator: "\n\n")), at: 0)
                syncQueuedFollowUpsToChat()
            }
        }
        pendingSteers.removeAll()
        if lastTurn?.steps.flatMap(\.toolCalls).contains(where: { $0.name == "add_memory" || $0.name == "edit_memory" }) == true {
            await app.memories.load()
            app.sync.request()
        }
        if let saves = changeSession {
            let receipts = await saves.receipts()
            var existing = Set((chat.saveReceipts ?? []).map(\.id))
            var newestReceipt: SaveReceipt?
            for receipt in receipts where existing.insert(receipt.id).inserted {
                chat.saveReceipts = (chat.saveReceipts ?? []) + [receipt]
                newestReceipt = receipt
            }
            if let newest = newestReceipt {
                if let cwBase = changeWorkspace?.base {
                    workspace = cwBase
                } else if let existingWorkspace = workspace {
                    workspace = existingWorkspace.advancing(toCommit: newest.savedCommit, branch: newest.branch)
                }
            }
        }
        flush()
        if var turn = lastTurn, turn.status == .running {
            turn.status = .stopped
            replaceLastTurn(turn)
        }
        // Spec mode writes the spec as files in the repo (Kiro parity, 11 November 2026), not as a
        // record inside the app: pick up the spec the AI started, and say what is waiting for approval.
        if effectiveMode == .spec, chat.repo != nil, let specChanges = changeWorkspace {
            let staged = await specChanges.stagedChanges().map(\.path)
            if let found = KiroSpecs.discovered(stagedPaths: staged, current: chat.kiroSpec, kind: specKind), found != chat.kiroSpec {
                chat.kiroSpec = found
                touch()
            }
            // Quick Spec has no gates: once tasks.md is written it lands on the task list.
            if let state = chat.kiroSpec, state.kind == .quick, state.phase != .implementation, let tasksPath = state.path(.tasks) {
                let hasTasks: Bool
                if case .text = try? await specChanges.read(tasksPath) { hasTasks = true } else { hasTasks = false }
                let next = KiroSpecs.afterQuickTurn(state, hasTasks: hasTasks)
                if next != state { chat.kiroSpec = next; touch() }
            }
            if let state = chat.kiroSpec, var current = lastTurn, current.status == .done,
               let notice = await Self.specPhaseNotice(state, workspace: specChanges) {
                if !current.notices.contains(notice) { current.notices.append(notice) }
                replaceLastTurn(current)
                specAwaitingApproval = state.phase != .implementation
            }
        }
        await refreshReviewState()
        if permissionMode == .supervised, unreviewedCount > 0, var current = lastTurn {
            let notice = "Supervised: \(unreviewedCount) changed file\(unreviewedCount == 1 ? " is" : "s are") waiting for your review. Tap Review changes to accept or reject each change before it's saved."
            if !current.notices.contains(notice) { current.notices.append(notice) }
            replaceLastTurn(current)
        }
        chat.updatedAt = Date()
        await nameChatIfNeeded()
    }

    /// Getting ready (connectors, the repo copy, the computer, the balance) may take this long in
    /// all before the AI is asked. Any of those waiting on a slow service used to hold the reply on
    /// "Thinking…" with nothing running yet.
    static let setupTimeLimit: TimeInterval = 120
    static let setupRanOutNotice = "Getting ready took over 2 minutes (connectors, the repo copy or the computer), so the reply started without waiting for the rest."
    @ObservationIgnored private var setupRanOut = false
    @ObservationIgnored private var setupTimer = ReplySetupTimer()

    /// Runs one getting-ready step within what is left of `deadline`, or returns `fallback`.
    private func setupStep<T: Sendable>(
        _ deadline: Date,
        fallback: T,
        label: String = "getting ready",
        countsAsRanOut: Bool = true,
        _ work: @escaping @Sendable () async -> T
    ) async -> T {
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else {
            if countsAsRanOut { setupRanOut = true }
            return fallback
        }
        let started = Date()
        defer { setupTimer.record(label, seconds: Date().timeIntervalSince(started)) }
        do {
            return try await AgentLoop.bounded(seconds: remaining, label: "Getting ready") { await work() }
        } catch {
            if countsAsRanOut, !(error is CancellationError) { setupRanOut = true }
            return fallback
        }
    }

    /// Real spend: reads the balance of the one provider this turn spends from, before it starts,
    /// and tells the app the turn is running on it, so turns that overlap on it are told apart.
    private func readBalanceBefore(modelID: String, app: AppModel, deadline: Date) async {
        guard let messageID = chat.messages.last?.id, let turn = lastTurn else { return }
        let provider = turn.balanceProvider ?? AIProviderModelID.providerID(modelID)
        if turn.balanceBefore == nil {
            let account = app.openRouter
            await setupStep(deadline, fallback: (), label: "reading balances") { await account.refreshKeyInfo() }
            guard var current = lastTurn, chat.messages.last?.id == messageID,
                  let balance = app.openRouter.balance(forProvider: provider) else { return }
            current.balanceBefore = balance
            current.balanceProvider = provider
            // Every provider's balance too: a fallback can move the reply to another provider.
            current.balancesBefore = app.openRouter.balancesByProvider
            replaceLastTurn(current)
        }
        app.balanceOverlaps.begin(messageID, provider: provider)
    }

    /// Publish the first snapshot immediately, then at most 30 times/second. Always deliver
    /// the latest trailing snapshot even if the provider pauses. Milestones never wait.
    private func receive(_ turn: AssistantTurn, milestone: Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        if let ready = streamedTurns.receive(turn, immediate: milestone || turn.status != .running, at: now) {
            flushTask?.cancel()
            flushTask = nil
            publish(ready, milestone: milestone)
        } else if flushTask == nil {
            let delay = UInt64(streamedTurns.delay(at: now) * 1_000_000_000)
            flushTask = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: delay) } catch { return }
                guard !Task.isCancelled else { return }
                self?.flush()
            }
        }
    }

    private func flush(scheduleSave: Bool = true) {
        flushTask?.cancel()
        flushTask = nil
        guard let turn = streamedTurns.flush(at: ProcessInfo.processInfo.systemUptime) else { return }
        publish(turn, milestone: turn.status != .running, scheduleSave: scheduleSave)
    }

    private func publish(_ turn: AssistantTurn, milestone: Bool, scheduleSave: Bool = true) {
        // Scanning all steps for steering on every token defeated the UI throttle.
        if !pendingSteers.isEmpty {
            let consumed = Set(turn.steps.flatMap { $0.steeredMessages ?? [] })
            if !consumed.isEmpty {
                pendingSteers.removeAll { consumed.contains($0.text) }
            }
        }
        replaceLastTurn(turn)
        if milestone || turn.status != .running { refreshStagedChanges() }
        if milestone || turn.status != .running || Date().timeIntervalSince(lastSaved) >= 4.0 {
            chat.updatedAt = Date()
            if scheduleSave { saveSoon() }
        }
    }

    /// Records the provider balance read after a turn, so the turn shows what it really cost.
    func recordBalanceAfter(_ balance: Double?, balances: [String: Double]?, messageID: UUID, shared: Bool = false) {
        guard let index = chat.messages.firstIndex(where: { $0.id == messageID }),
              var turn = chat.messages[index].assistantTurn,
              turn.balanceBefore != nil, turn.status != .running else { return }
        if let balance { turn.balanceAfter = balance }
        if let balances, turn.balancesBefore != nil { turn.balancesAfter = balances }
        if shared { turn.balanceShared = true }
        chat.messages[index].assistantTurn = turn
        saveSoon()
    }

    private func replaceLastTurn(_ turn: AssistantTurn) {
        guard let index = chat.messages.indices.last, chat.messages[index].assistantTurn != nil else { return }
        chat.messages[index].assistantTurn = turn
    }

    /// Runs a workflow the chat itself decided on, here in the chat. The run's card shows each
    /// step live, this turn says how far it has got, and the result is the turn's reply.
    private func runRoutedWorkflow(_ workflow: WorkflowDefinition, request: String, defaultModelID: String, agents: [AgentDefinition], toolPool: [any AgentTool], repoContext: SystemPrompt.RepoContext?) async {
        guard var turn = lastTurn else { return }
        turn.status = .running
        turn.routeLabel = "Workflow · \(workflow.name)"
        var step = AssistantStep()
        step.text = "Running the \(workflow.name) workflow in this chat…"
        turn.steps.append(step)
        replaceLastTurn(turn)
        let stepID = step.id
        routedWorkflowStepID = stepID
        defer { routedWorkflowStepID = nil }
        let snapshot = await executeChatWorkflow(
            definition: workflow,
            prompt: request,
            defaultModelID: defaultModelID,
            allAgents: agents,
            toolPool: toolPool,
            repoContext: repoContext,
            progress: { _ in }
        )
        guard var finished = lastTurn else { return }
        if let index = finished.steps.firstIndex(where: { $0.id == stepID }) {
            finished.steps[index].text = snapshot.chatReply()
            finished.steps[index].finishedAt = Date()
        }
        finished.status = userStoppedExplicitly ? .stopped : .done
        replaceLastTurn(finished)
    }

    /// The step of this chat's turn that shows a chat-started workflow's progress, while it runs.
    @ObservationIgnored private var routedWorkflowStepID: UUID?

    private func showRoutedWorkflowProgress(_ run: ActiveWorkflowRunSnapshot) {
        guard let stepID = routedWorkflowStepID, var turn = lastTurn, turn.status == .running,
              let index = turn.steps.firstIndex(where: { $0.id == stepID }) else { return }
        turn.steps[index].text = run.chatProgressLine()
        replaceLastTurn(turn)
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

    private struct MissingConnection: Error { let message: String }

    /// Reading, editing and saving tools for one of the chat's other repos, with its own staged
    /// changes, working branch (an open request's branch when there is one) and save rules.
    private func extraRepoTools(
        _ extra: ChatRepo, app: AppModel, saves: ChangeSession, authorization changeAuthorization: ChangeAuthorization, lastMessage: String, setupDeadline: Date
    ) async throws -> (tools: [any AgentTool], helpers: [any AgentTool]) {
        guard let client = app.repoClient(for: extra.ref) else {
            throw MissingConnection(message: "Connect \(extra.ref.hostName) so MAIPA-G can read \(extra.ref.fullName).")
        }
        let active = await saves.activeReceipt(for: extra.ref)
        var branch = active?.branch ?? extra.branch
        if let active, let pull = active.pullRequest, let current = try? await client.pullRequest(extra.ref, number: pull.number), current.state != "open" {
            // Its request was closed or merged on the website: start again from the chosen branch.
            branch = extra.branch
            await saves.markResolved(active.id, as: "closed")
            if var receipts = chat.saveReceipts, let index = receipts.firstIndex(where: { $0.id == active.id }) {
                receipts[index].resolution = "closed"
                chat.saveReceipts = receipts
            }
        }
        let commit = try await client.resolveCommit(extra.ref, ref: branch)
        let base: RepoWorkspace
        let changes: ChangeWorkspace
        if let existing = extraChangeWorkspaces[extra.ref], existing.base.branch == branch {
            if existing.base.commit == commit {
                changes = existing
            } else {
                changes = await existing.rebased(onto: RepoWorkspace(repo: extra.ref, branch: branch, commit: commit, github: client, store: app.snapshots))
                extraChangeWorkspaces[extra.ref] = changes
            }
            base = changes.base
        } else {
            base = RepoWorkspace(repo: extra.ref, branch: branch, commit: commit, github: client, store: app.snapshots)
            changes = ChangeWorkspace(base: base)
            extraChangeWorkspaces[extra.ref] = changes
        }
        await setupStep(setupDeadline, fallback: ()) { await base.prefetch() }
        let service = GitHubChangeService(github: client)
        let rules = await service.resolveRules(in: base, directSaveSetting: app.settings.savesDirectly(to: extra.ref), requestText: lastMessage)
        let helpers: [any AgentTool] = [
            ListFilesTool(workspace: base, changes: changes),
            SearchCodeTool(workspace: base, changes: changes),
            ReadFileTool(workspace: base, changes: changes),
            LoadRepoRulesTool(documents: rules.documents),
        ]
        return (helpers + [
            CreateFileTool(workspace: changes, authorization: changeAuthorization, rules: rules),
            EditFileTool(workspace: changes, authorization: changeAuthorization, rules: rules),
            AppendFileTool(workspace: changes, authorization: changeAuthorization, rules: rules),
            DeleteFileTool(workspace: changes, authorization: changeAuthorization, rules: rules),
            SaveChangesTool(workspace: changes, service: service, session: saves, selectedBranch: branch, defaultBranch: extra.defaultBranch, rules: rules),
        ], helpers)
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
    private func shouldPrewarmComputer(repo: SystemPrompt.RepoContext?, hasStagedChanges: Bool, lastUserMessage: String, isAutonomous: Bool) -> Bool {
        if isAutonomous || hasStagedChanges { return true }
        let low = lastUserMessage.lowercased()
        let computerKeywords = [
            "sprite", "computer", "linux", "machine", "shell", "bash", "terminal", "command",
            "build", "test", "compile", "swift ", "python", "node", "npm", "git ", "wake",
            "install", "script", "server", "port", "benchmark", "docker", "cargo", "pytest",
        ]
        if computerKeywords.contains(where: { low.contains($0) }) { return true }
        return false
    }

    private func prepareComputer(app: AppModel, repo: SystemPrompt.RepoContext?, lastUserMessage: String, isAutonomous: Bool) async -> String? {
        guard app.openRouter.supportsTools(chat.model), let control = app.connectors.computerControl(), control.commandTool != nil else { return nil }
        let stagedChanges = await changeWorkspace?.stagedChanges() ?? []
        guard shouldPrewarmComputer(repo: repo, hasStagedChanges: !stagedChanges.isEmpty, lastUserMessage: lastUserMessage, isAutonomous: isAutonomous) else {
            // Keep the Sprite sleeping ($0/hr) on plain Q&A turns; `mcp_sprites_*` tools remain connected so the AI can wake it on demand if needed.
            return nil
        }
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
                        app.connectors.keepComputerAwakeDuringSetup()
                        notes.append("MAIPA-G's checked tool set is still installing on this machine in the background. Use the tools that are there; if one is missing, say which and that it is still installing.")
                    case .missing:
                        let revision = Bundle.main.object(forInfoDictionaryKey: "MAIPAGReviewedRevision") as? String ?? ""
                        do {
                            notes.append(try await control.startVerifiedSetup(revision: revision))
                            app.connectors.keepComputerAwakeDuringSetup(resetReadyCache: true)
                        }
                        catch { notes.append("MAIPA-G couldn't start installing its tools: \(ErrorExplainer.explain(error).message)") }
                    }
                case .recreated:
                    notes.append("`\(control.machine)` was missing, so MAIPA-G's own code created it again with that exact name and checked it with a real command.")
                    let revision = Bundle.main.object(forInfoDictionaryKey: "MAIPAGReviewedRevision") as? String ?? ""
                    do {
                        notes.append(try await control.startVerifiedSetup(revision: revision))
                        app.connectors.keepComputerAwakeDuringSetup(resetReadyCache: true)
                    }
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
                    let status = try await control.syncStagedChanges(homePath: "repos/\(repo.ref.owner)/\(repo.ref.name)", cloneURL: repo.isPrivate ? nil : repo.ref.webURL.absoluteString + ".git", commit: repo.commit, changes: changes)
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
        let cloneURL = repo.ref.webURL.absoluteString + ".git"
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

    static func provisionalAttachmentTitle(_ attachments: [AttachmentReference]) -> String {
        guard !attachments.isEmpty else { return "New chat" }
        let images = attachments.filter { $0.kind == .image }
        if images.count == attachments.count {
            return images.count == 1 ? "Photo" : "\(images.count) photos"
        }
        return attachments.count == 1 ? provisionalTitle(attachments[0].name) : "\(attachments.count) attachments"
    }

    /// After the first reply, asks the iPhone's own AI for a better title.
    private func nameChatIfNeeded() async {
        guard !chat.titleIsCustom,
              chat.messages.filter({ $0.userText != nil }).count == 1,
              let firstUserMsg = chat.messages.first(where: { $0.userText != nil }),
              case .user(let userPayload) = firstUserMsg.body,
              let turn = lastTurn, turn.status == .done
        else { return }
        let message = userPayload.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let expectedProvisional = message.isEmpty
            ? Self.provisionalAttachmentTitle(userPayload.attachments)
            : Self.provisionalTitle(message)
        guard chat.title == expectedProvisional else { return }
        let reply = turn.steps.last(where: { !$0.text.isEmpty })?.text ?? ""
        let seed = message.isEmpty ? "User shared \(expectedProvisional.lowercased())" : message
        if let title = await OnDeviceAI.title(message: seed, reply: reply), !chat.titleIsCustom {
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
            self.flush(scheduleSave: false)
            self.lastSaved = Date()
            await app.library.save(self.chat)
        }
    }
    /// Downscales and JPEG-compresses oversized screenshots/photos solely for the wire request so
    /// 15–20 attached screenshots stay crisp for vision models without hitting Cloudflare 413 limits.
    nonisolated static func compactWireImageData(_ raw: Data, maxDimension: CGFloat = 1_600) -> Data {
        guard let image = UIImage(data: raw), image.size.width > 1, image.size.height > 1 else {
            return raw
        }
        let scaleFactor = min(1.0, maxDimension / max(image.size.width, image.size.height))
        let targetSize = CGSize(
            width: max(1, floor(image.size.width * scaleFactor)),
            height: max(1, floor(image.size.height * scaleFactor))
        )
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1.0
        format.opaque = true
        let rendered = UIGraphicsImageRenderer(size: targetSize, format: format).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: targetSize))
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
        if let jpeg = rendered.jpegData(compressionQuality: 0.78), jpeg.count < raw.count {
            return jpeg
        }
        return raw
    }

    // MARK: Pure Image-Generation Model Turns, Workstation Files, & Kiro Chat Workflows

    private func runPureImageTurn(
        model: ModelInfo,
        prompt: String,
        attachments: [AttachmentReference] = [],
        client: OpenRouterClient,
        app: AppModel
    ) async {
        let cleanPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        // Pictures go to the model as input when it takes images: the ones attached to this
        // message, or, when the message talks about an earlier picture, the chat's latest one.
        var inputPictures = attachments.filter { $0.kind == .image }
        if inputPictures.isEmpty, ImageEditIntent.refersToEarlierPicture(cleanPrompt), let latest = chatPictures().last {
            inputPictures = [latest]
        }
        let takesPictures = model.acceptsImages
        let sentPictures = takesPictures ? inputPictures : []
        // Anything the model can't take is named plainly, never dropped silently.
        let notSent = attachments.filter { !sentPictures.contains($0) } + (takesPictures ? [] : inputPictures.filter { !attachments.contains($0) })
        let ignoredNote: String = {
            guard !notSent.isEmpty else { return "" }
            let names = notSent.map(\.name).joined(separator: ", ")
            if !takesPictures, notSent.contains(where: { $0.kind == .image }) {
                return "Not sent to \(model.shortName): \(names). \(model.shortName) can't take a picture as input; it only makes pictures from a written description, so this one was made from your words alone. Pick a picture model that accepts images to edit a picture."
            }
            return "Not sent to \(model.shortName): \(names). Picture models only take pictures and a written description, not other files."
        }()
        guard !cleanPrompt.isEmpty else {
            fail(.other, "Describe the picture you want \(model.shortName) to generate"
                + (sentPictures.isEmpty ? "." : " from your picture.")
                + (ignoredNote.isEmpty ? "" : " " + ignoredNote))
            return
        }
        // A billed picture goes through `generate_image`'s own approval, the same pause every
        // other tool uses: a waiting tool call whose first option allows it.
        let imageTool = GenerateImageTool(client: client, store: app.attachmentStore, model: model.id, maySpend: !model.isFree, availableImages: sentPictures)
        var arguments: JSONValue = [
            "prompt": .string(cleanPrompt),
            "aspect_ratio": .string(ImageAspectRatio.square.rawValue),
            "quality": .string(ImageQuality.standard.rawValue),
        ]
        if !sentPictures.isEmpty {
            arguments = [
                "prompt": .string(cleanPrompt),
                "aspect_ratio": .string(ImageAspectRatio.square.rawValue),
                "quality": .string(ImageQuality.standard.rawValue),
                "reference_images": .array(sentPictures.map { .string($0.name) }),
            ]
        }
        var approved = false
        if let waiting = lastTurn?.steps.last?.toolCalls.last, waiting.name == imageTool.name, let questions = waiting.questions {
            guard let answer = questions.answers?.first else { return }
            let normalized = answer.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let affirmative: Set<String> = ["yes", "y", "allow", "approve", "approved", "sure", "ok", "okay", "go ahead", "do it"]
            guard questions.questions.first?.options.first == answer || affirmative.contains(normalized) else {
                var turn = lastTurn ?? AssistantTurn()
                var declinedStep = AssistantStep()
                declinedStep.model = model.id
                declinedStep.text = "No picture was generated: the billed request wasn't approved."
                declinedStep.finishedAt = Date()
                turn.steps = [declinedStep]
                turn.status = .done
                replaceLastTurn(turn)
                return
            }
            arguments = waiting.parsedArguments
            approved = true
        } else if let approval = await imageTool.approvalRequest(for: arguments) {
            var turn = lastTurn ?? AssistantTurn()
            let argumentText = (try? JSONCoding.encoder().encode(arguments)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            var call = ToolCallRecord(id: UUID().uuidString, name: imageTool.name, arguments: argumentText, summary: "Needs your approval", status: .waitingForUser)
            call.questions = QuestionSet(questions: [.init(text: approval.question, options: [approval.allowLabel, "Don't allow"])])
            var waitingStep = AssistantStep()
            waitingStep.model = model.id
            waitingStep.toolCalls = [call]
            turn.steps = [waitingStep]
            turn.status = .waitingForUser
            replaceLastTurn(turn)
            return
        }
        if var turn = lastTurn {
            turn.status = .running
            var runningStep = AssistantStep()
            runningStep.model = model.id
            runningStep.text = "Generating picture with \(model.shortName)…"
            turn.steps = [runningStep]
            replaceLastTurn(turn)
        }
        do {
            let output: ToolOutput
            if approved {
                output = try await imageTool.runApproved(arguments: arguments, progress: { _ in })
            } else {
                output = try await imageTool.run(arguments: arguments, progress: { _ in })
            }
            let savedResults = output.generatedImages
            var turn = lastTurn ?? AssistantTurn()
            var finishedStep = AssistantStep()
            finishedStep.model = model.id
            finishedStep.text = savedResults.isEmpty
                ? "No picture was returned by \(model.shortName)."
                : (sentPictures.isEmpty ? "Generated with **\(model.shortName)**." : "Made with **\(model.shortName)** from \(sentPictures.map(\.name).joined(separator: ", ")).")
            if !ignoredNote.isEmpty {
                finishedStep.text += "\n\n" + ignoredNote
            }
            finishedStep.generatedImages = savedResults.isEmpty ? nil : savedResults
            finishedStep.finishedAt = Date()
            turn.steps = [finishedStep]
            turn.status = .done
            replaceLastTurn(turn)
            chat.updatedAt = Date()
            await nameChatIfNeeded()
        } catch let apiErr as OpenRouterAPIError where apiErr.kind == .outOfCredits {
            app.openRouter.markOutOfCredits()
            fail(.outOfCredits, app.openRouter.describe(apiErr))
        } catch {
            fail(.other, app.openRouter.describe(error))
        }
    }

    /// Every picture in the chat, oldest first: ones attached to messages and ones generated here.
    func chatPictures() -> [AttachmentReference] {
        var pictures: [AttachmentReference] = []
        for message in chat.messages {
            switch message.body {
            case .user(let user):
                pictures += user.attachments.filter { $0.kind == .image }
            case .assistant(let turn):
                pictures += turn.steps.flatMap { $0.generatedImages ?? [] }.map(\.attachment)
            }
        }
        var seen = Set<UUID>()
        return pictures.filter { seen.insert($0.id).inserted }
    }

    func collectWorkstationItems() async -> [WorkstationFileItem] {
        var items: [WorkstationFileItem] = []
        var seen = Set<String>()

        for ref in workstationFiles {
            let key = ref.id.uuidString.lowercased()
            if seen.insert(key).inserted {
                items.append(WorkstationFileItem(
                    id: key,
                    name: ref.name,
                    mimeType: ref.mimeType,
                    byteCount: ref.bytes,
                    source: "workstation",
                    attachment: ref
                ))
            }
        }
        for message in chat.messages {
            switch message.body {
            case .user(let u):
                for ref in u.attachments {
                    let key = ref.id.uuidString.lowercased()
                    if seen.insert(key).inserted {
                        items.append(WorkstationFileItem(
                            id: key,
                            name: ref.name,
                            mimeType: ref.mimeType,
                            byteCount: ref.bytes,
                            source: "chat_attachment",
                            attachment: ref
                        ))
                    }
                }
            case .assistant(let turn):
                for img in turn.steps.flatMap({ $0.generatedImages ?? [] }) {
                    let ref = img.attachment
                    let key = ref.id.uuidString.lowercased()
                    if seen.insert(key).inserted {
                        items.append(WorkstationFileItem(
                            id: key,
                            name: ref.name,
                            mimeType: ref.mimeType,
                            byteCount: ref.bytes,
                            source: "generated_image",
                            attachment: ref
                        ))
                    }
                }
            }
        }
        if let cw = changeWorkspace {
            let staged = await cw.stagedChanges()
            for change in staged {
                guard case .write(let path, let data, _) = change else { continue }
                let id = "staged:\(path)"
                if seen.insert(id).inserted {
                    items.append(WorkstationFileItem(
                        id: id,
                        name: path,
                        mimeType: "text/plain",
                        byteCount: data.count,
                        source: "staged_repo_file",
                        stagedPath: path
                    ))
                }
            }
        }
        return items
    }

    func executeChatWorkflow(
        definition: WorkflowDefinition,
        prompt: String,
        defaultModelID: String,
        allAgents: [AgentDefinition],
        toolPool: [any AgentTool],
        repoContext: SystemPrompt.RepoContext?,
        progress: @escaping @Sendable (String) -> Void
    ) async -> ActiveWorkflowRunSnapshot {
        guard let app else {
            return ActiveWorkflowRunSnapshot(
                id: definition.id,
                definition: definition,
                checkpoint: WorkflowCheckpoint(workflowID: definition.id, request: prompt),
                isRunning: false,
                errorMessage: "App closed."
            )
        }
        let runID = "wf-\(UUID().uuidString.prefix(8).lowercased())"
        let resolvedDefaultModel = defaultModelID == ModelChoice.freeID ? ModelChoice.autoID : defaultModelID
        let defaultEffort: ThinkingLevel = .max
        let aiClient = app.openRouter.client
        let catalogue = app.openRouter.modelsByID
        let accountState = app.openRouter.accountState
        let hasOpenRouter = app.openRouter.hasOpenRouterKey
        let userLogin = app.github.login
        let connectedRepoNames = app.github.repos.map(\.fullName)
        let spendLimit = app.settings.spendLimitOn ? app.settings.spendLimit : nil

        var approvedDef = definition
        approvedDef.isApproved = true

        let initialCheckpoint = WorkflowCheckpoint(
            workflowID: approvedDef.id,
            request: prompt,
            defaultModelID: resolvedDefaultModel,
            defaultEffort: defaultEffort
        )
        upsertWorkflowSnapshot(ActiveWorkflowRunSnapshot(
            id: runID,
            definition: approvedDef,
            checkpoint: initialCheckpoint,
            isRunning: true
        ))

        let engine = WorkflowEngine(
            definition: approvedDef,
            checkpoint: initialCheckpoint,
            agents: allAgents + BuiltInAgents.allIncludingKiroSubagents,
            defaultModelID: resolvedDefaultModel,
            defaultEffort: defaultEffort,
            spendLimit: spendLimit,
            onMessage: { [weak self] msg in
                progress("\(msg.title): \(msg.message)")
                await MainActor.run {
                    self?.refreshWorkflowSnapshotFromMessage(runID: runID, event: msg)
                }
            },
            runner: { invocation in
                let chosenModelID: String = {
                    if let override = invocation.preferredModelID, !override.isEmpty, override != ModelChoice.freeID {
                        return override
                    }
                    return resolvedDefaultModel
                }()
                let stepChoice: ModelChoice = chosenModelID == ModelChoice.autoID ? .auto : .model(chosenModelID)
                let stepEffort = invocation.preferredEffort ?? defaultEffort
                let stepRoute = ModelRouter.route(
                    choice: stepChoice,
                    difficulty: invocation.definition.difficulty,
                    thinking: stepEffort,
                    account: accountState,
                    catalogue: catalogue,
                    requiresImageInput: false,
                    openRouterAvailable: hasOpenRouter
                )
                var stepChat = Chat(model: stepChoice, thinking: stepEffort)
                stepChat.messages.append(.user(invocation.task))
                stepChat.messages.append(ChatMessage(body: .assistant(AssistantTurn())))
                let stepPrompt = SystemPrompt.make(
                    userLogin: userLogin,
                    repo: repoContext,
                    agent: invocation.definition,
                    workflowContext: invocation.context,
                    connectedRepositories: connectedRepoNames
                )
                let extraTools = invocation.tools
                let mergedPool = (toolPool + extraTools).filter { invocation.definition.permits(tool: $0.name) || $0.name == "send_message" }
                let stepInput = AgentTurnInput(
                    chat: stepChat,
                    route: stepRoute,
                    systemPrompt: stepPrompt,
                    tools: mergedPool,
                    allowTools: true,
                    maxSteps: 400,
                    spendLimit: invocation.spendLimit,
                    requiresInitialSpendApproval: false,
                    agent: invocation.definition,
                    allowAskUser: false
                )
                let stepEnv = AgentEnvironment(
                    openRouter: aiClient,
                    freeRoute: {
                        ModelRouter.route(choice: .free, difficulty: .normal, thinking: .default, account: AccountState(), catalogue: catalogue, openRouterAvailable: hasOpenRouter)
                    },
                    onOutOfCredits: {}
                )
                let stepRun = AgentLoop.start(stepInput, environment: stepEnv)
                var finalTurn: AssistantTurn?
                do {
                    for await event in stepRun.events {
                        try Task.checkCancellation()
                        if case .updated(let updated, _) = event {
                            finalTurn = updated
                        }
                    }
                } catch is CancellationError {
                    stepRun.cancel()
                    throw CancellationError()
                }
                let allCalls = finalTurn?.steps.flatMap(\.toolCalls) ?? []
                let joinedText = finalTurn?.steps.map(\.text)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n\n") ?? ""
                if finalTurn?.status == .failed {
                    let message = finalTurn?.failure?.message ?? "Workflow step failed."
                    throw ToolInputError(joinedText.isEmpty ? message : "\(joinedText)\n\nError: \(message)")
                }
                let fallbackReasoning = finalTurn?.steps.reversed()
                    .map { $0.reasoning.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .first(where: { !$0.isEmpty })
                let text = !joinedText.isEmpty ? joinedText : (fallbackReasoning ?? "Step completed.")
                return AgentExecutionResult(
                    output: text,
                    model: finalTurn?.modelsUsed.last ?? stepRoute.model,
                    goalOutcome: AgentGoalOutcome.parse(text),
                    cost: finalTurn?.usage.cost ?? 0,
                    toolCallCount: allCalls.count,
                    toolSummaries: allCalls.map(\.summary),
                    status: "completed"
                )
            },
            checkpointer: { [weak self] cp in
                await MainActor.run {
                    guard let self, let idx = self.activeWorkflowRuns.firstIndex(where: { $0.id == runID }) else { return }
                    self.activeWorkflowRuns[idx].checkpoint = cp
                    // Same checkpoint as the card, at the same moment, so the line never lags it.
                    self.showRoutedWorkflowProgress(self.activeWorkflowRuns[idx])
                }
            }
        )
        workflowEngines[runID] = engine
        progress("Running workflow \(approvedDef.name)…")
        let outcome = await engine.run(request: prompt)
        let currentDef = await engine.definition
        let finalSnapshot: ActiveWorkflowRunSnapshot
        switch outcome {
        case .completed(let cp):
            finalSnapshot = ActiveWorkflowRunSnapshot(id: runID, definition: currentDef, checkpoint: cp, isRunning: false)
        case .waiting(let cp, _):
            finalSnapshot = ActiveWorkflowRunSnapshot(id: runID, definition: currentDef, checkpoint: cp, isRunning: false)
        case .cancelled(let cp):
            finalSnapshot = ActiveWorkflowRunSnapshot(id: runID, definition: currentDef, checkpoint: cp, isRunning: false)
        case .failed(let cp, let err):
            finalSnapshot = ActiveWorkflowRunSnapshot(id: runID, definition: currentDef, checkpoint: cp, isRunning: false, errorMessage: err)
        }
        upsertWorkflowSnapshot(finalSnapshot)
        return finalSnapshot
    }

    /// Stops every workflow run left marked "running" by a previous app session. Their engines are
    /// gone, so their Pause/Stop buttons could never work; nothing else clears them.
    func settleInterruptedWorkflowRunsOnLaunch() {
        var changed = false
        for idx in activeWorkflowRuns.indices where activeWorkflowRuns[idx].isRunning {
            guard workflowEngines[activeWorkflowRuns[idx].id] == nil else { continue }
            activeWorkflowRuns[idx].isRunning = false
            activeWorkflowRuns[idx].checkpoint.isCancelled = true
            activeWorkflowRuns[idx].errorMessage = "Interrupted by app restart"
            changed = true
        }
        guard changed else { return }
        chat.activeWorkflowRuns = activeWorkflowRuns
        saveSoon(immediately: true)
    }

    private func upsertWorkflowSnapshot(_ snapshot: ActiveWorkflowRunSnapshot) {
        if let idx = activeWorkflowRuns.firstIndex(where: { $0.id == snapshot.id }) {
            activeWorkflowRuns[idx] = snapshot
        } else {
            activeWorkflowRuns.insert(snapshot, at: 0)
        }
        chat.activeWorkflowRuns = activeWorkflowRuns
    }

    private func refreshWorkflowSnapshotFromMessage(runID: String, event: WorkflowMessageEvent) {
        guard let idx = activeWorkflowRuns.firstIndex(where: { $0.id == runID }) else { return }
        if !activeWorkflowRuns[idx].checkpoint.sentMessages.contains(where: { $0.id == event.id }) {
            activeWorkflowRuns[idx].checkpoint.sentMessages.append(event)
        }
    }

    func inspectWorkflowsReport(query: String?, app: AppModel?) -> String {
        if let q = query?.trimmingCharacters(in: .whitespacesAndNewlines), !q.isEmpty {
            if let run = activeWorkflowRuns.first(where: { $0.id == q || $0.definition.id == q || $0.definition.name.caseInsensitiveCompare(q) == .orderedSame }) {
                return run.formattedTreeSummary()
            }
            if let def = app?.automations.workflows.first(where: { $0.id == q || $0.name.caseInsensitiveCompare(q) == .orderedSame }) {
                let stepLines = def.steps.map { "- \($0.title) (`\($0.id)`, \($0.kind.rawValue))" }.joined(separator: "\n")
                return "Saved workflow: \(def.name) (`\(def.id)`)\nSummary: \(def.summary)\nSteps:\n\(stepLines)"
            }
            return "No active workflow run or saved workflow matches `\(q)`."
        }
        var sections: [String] = []
        if !activeWorkflowRuns.isEmpty {
            sections.append("## Active / Recent Workflow Runs in This Chat\n" + activeWorkflowRuns.map { $0.formattedTreeSummary() }.joined(separator: "\n\n"))
        } else {
            sections.append("No workflow runs in this chat yet.")
        }
        if let workflows = app?.automations.workflows, !workflows.isEmpty {
            let list = workflows.map { "- `\($0.id)` — \($0.name): \($0.summary)" }.joined(separator: "\n")
            sections.append("## Available Workflows\n\(list)")
        }
        return sections.joined(separator: "\n\n")
    }

    func replaceRemainingWorkflowSteps(runID: String?, steps: [WorkflowNode]) async throws -> String {
        let targetID = runID ?? activeWorkflowRuns.first?.id
        guard let targetID, let engine = workflowEngines[targetID] else {
            throw ToolInputError("No active workflow run found to update. A run left over from a previous app session can only be stopped or retried, not edited.")
        }
        let updated = try await engine.replaceRemainingSteps(steps)
        let cp = await engine.state
        if let idx = activeWorkflowRuns.firstIndex(where: { $0.id == targetID }) {
            activeWorkflowRuns[idx].definition = updated
            activeWorkflowRuns[idx].checkpoint = cp
            chat.activeWorkflowRuns = activeWorkflowRuns
        }
        return "Updated workflow `\(updated.name)` (`\(targetID)`): now \(updated.steps.count) total top-level steps."
    }

    // UI Controls for Inline `ACTIVE WORKFLOWS` Tree Card & `Workstation` `Workflows` Tab

    func pauseWorkflowRun(_ runID: String) {
        guard let engine = workflowEngines[runID] else {
            // Only a restarted run reaches here. Asking to pause it must still settle it, otherwise
            // Pause is a button that never does anything.
            stopWorkflowRun(runID)
            return
        }
        Task { await engine.requestPause() }
    }

    func stopWorkflowRun(_ runID: String) {
        workflowTasks[runID]?.cancel()
        workflowTasks[runID] = nil
        guard let engine = workflowEngines[runID] else {
            // The workflow engine only lives in memory, so after an app restart a chat can reload a
            // run marked "running" with nothing behind it. Stopping that run used to do nothing at
            // all, leaving a card whose Stop/Pause never worked and a chat the app treated as busy
            // forever. Settle it by hand instead of silently returning.
            guard let idx = activeWorkflowRuns.firstIndex(where: { $0.id == runID }) else { return }
            activeWorkflowRuns[idx].isRunning = false
            activeWorkflowRuns[idx].checkpoint.isCancelled = true
            activeWorkflowRuns[idx].errorMessage = "Interrupted by app restart"
            chat.activeWorkflowRuns = activeWorkflowRuns
            saveSoon(immediately: true)
            return
        }
        Task {
            await engine.cancel()
            let cp = await engine.state
            let def = await engine.definition
            await MainActor.run {
                self.upsertWorkflowSnapshot(ActiveWorkflowRunSnapshot(id: runID, definition: def, checkpoint: cp, isRunning: false))
            }
        }
    }

    func steerWorkflowRun(_ runID: String, note: String) {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let engine = workflowEngines[runID] else { return }
        Task {
            try? await engine.steer(trimmed)
            let cp = await engine.state
            await MainActor.run {
                if let idx = self.activeWorkflowRuns.firstIndex(where: { $0.id == runID }) {
                    self.activeWorkflowRuns[idx].checkpoint = cp
                    self.chat.activeWorkflowRuns = self.activeWorkflowRuns
                }
            }
        }
    }

    func setWorkflowRunModel(_ runID: String, modelID: String, effort: ThinkingLevel? = nil) {
        guard modelID != ModelChoice.freeID else { return }
        guard let engine = workflowEngines[runID] else {
            // A restarted run has no engine left to switch, so record the choice for a later resume.
            guard let idx = activeWorkflowRuns.firstIndex(where: { $0.id == runID }) else { return }
            activeWorkflowRuns[idx].checkpoint.defaultModelID = modelID
            activeWorkflowRuns[idx].checkpoint.defaultEffort = effort
            chat.activeWorkflowRuns = activeWorkflowRuns
            saveSoon(immediately: true)
            return
        }
        Task {
            try? await engine.setDefaultModel(modelID, effort: effort)
            let cp = await engine.state
            await MainActor.run {
                if let idx = self.activeWorkflowRuns.firstIndex(where: { $0.id == runID }) {
                    self.activeWorkflowRuns[idx].checkpoint = cp
                    self.chat.activeWorkflowRuns = self.activeWorkflowRuns
                }
            }
        }
    }

    func resumeWorkflowRun(_ runID: String, answer: String? = nil) {
        guard let engine = workflowEngines[runID],
              let idx = activeWorkflowRuns.firstIndex(where: { $0.id == runID }),
              !activeWorkflowRuns[idx].isRunning else { return }
        activeWorkflowRuns[idx].isRunning = true
        activeWorkflowRuns[idx].errorMessage = nil
        let pendingNodeID = activeWorkflowRuns[idx].checkpoint.pendingQuestion?.nodeID
        workflowTasks[runID] = Task { [weak self] in
            if let pendingNodeID {
                try? await engine.answer(nodeID: pendingNodeID, answer: answer ?? "Resume")
            }
            let outcome = await engine.run()
            let def = await engine.definition
            await MainActor.run {
                guard let self else { return }
                self.workflowTasks[runID] = nil
                switch outcome {
                case .completed(let cp):
                    self.upsertWorkflowSnapshot(ActiveWorkflowRunSnapshot(id: runID, definition: def, checkpoint: cp, isRunning: false))
                case .waiting(let cp, _):
                    self.upsertWorkflowSnapshot(ActiveWorkflowRunSnapshot(id: runID, definition: def, checkpoint: cp, isRunning: false))
                case .cancelled(let cp):
                    self.upsertWorkflowSnapshot(ActiveWorkflowRunSnapshot(id: runID, definition: def, checkpoint: cp, isRunning: false))
                case .failed(let cp, let err):
                    self.upsertWorkflowSnapshot(ActiveWorkflowRunSnapshot(id: runID, definition: def, checkpoint: cp, isRunning: false, errorMessage: err))
                }
            }
        }
    }

    func retryWorkflowRun(_ runID: String) {
        guard let snap = activeWorkflowRuns.first(where: { $0.id == runID }), !snap.isRunning, let app,
              app.settings.workflowsEnabled else { return }
        let catalogue = app.openRouter.modelsByID
        let route = ModelRouter.route(
            choice: chat.model,
            difficulty: .normal,
            thinking: .max,
            account: app.openRouter.accountState,
            catalogue: catalogue,
            requiresImageInput: false,
            openRouterAvailable: app.openRouter.hasOpenRouterKey
        )
        let defaultModel = snap.checkpoint.defaultModelID ?? route.model
        let prompt = snap.checkpoint.request
        let def = snap.definition
        activeWorkflowRuns.removeAll { $0.id == runID }
        chat.activeWorkflowRuns = activeWorkflowRuns
        workflowEngines[runID] = nil
        let tools: [any AgentTool] = webEnabled ? [WebSearchTool(transport: app.transport), ReadWebPageTool(transport: app.transport)] : []
        Task { [weak self] in
            guard let self else { return }
            _ = await self.executeChatWorkflow(
                definition: def,
                prompt: prompt,
                defaultModelID: defaultModel,
                allAgents: app.automations.agents,
                toolPool: tools + app.connectors.agentTools(),
                repoContext: nil,
                progress: { _ in }
            )
        }
    }
}
