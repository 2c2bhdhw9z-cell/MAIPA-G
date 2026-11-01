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
    private(set) var isRunning = false
    private(set) var isCompacting = false
    /// Unconsumed live steering notes waiting for the active run's next safe step boundary.
    private(set) var pendingSteers: [String] = []
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
    @ObservationIgnored private var workspace: RepoWorkspace?
    @ObservationIgnored private var changeWorkspace: ChangeWorkspace?
    @ObservationIgnored private var workflowEngines: [String: WorkflowEngine] = [:]
    @ObservationIgnored private var workflowTasks: [String: Task<Void, Never>] = [:]
    var currentChangeWorkspace: ChangeWorkspace? { changeWorkspace }
    var hasActiveWorkflowRuns: Bool { activeWorkflowRuns.contains(where: \.isRunning) }
    var hasInMemoryWorkToPreserve: Bool {
        changeWorkspace != nil || !workstationFiles.isEmpty || !activeWorkflowRuns.isEmpty
    }

    func hasUnsavedStagedWork() async -> Bool {
        await changeWorkspace?.hasStagedChanges() ?? false
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
    @ObservationIgnored private var pendingTurn: AssistantTurn?
    @ObservationIgnored private var flushScheduled = false
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
        flush()
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
            if busySendMode == .steer, attachments.isEmpty, let activeRun = run {
                pendingSteers.append(message)
                Task { await activeRun.steer(message) }
            } else {
                queuedSteering.append(QueuedFollowUp(text: message, attachments: attachments))
                syncQueuedFollowUpsToChat()
            }
            return
        }
        pausedInBackground = false
        userStoppedExplicitly = false
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
    func cancelPendingSteer(at index: Int) {
        guard pendingSteers.indices.contains(index) else { return }
        let removed = pendingSteers.remove(at: index)
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
                if record.result == nil {
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
        await changeWorkspace?.stagedDiff() ?? "No staged changes in this turn."
    }

    func currentStagedChanges() async -> [StagedChange] {
        await changeWorkspace?.stagedChanges() ?? []
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
        pausedInBackground = false
        userStoppedExplicitly = true
        pendingSteers.removeAll()
        guard isRunning else {
            settleWaitingTurn()
            return
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
        guard !isRunning, let index = chat.messages.firstIndex(where: { $0.id == messageID }),
              chat.messages[index].assistantTurn != nil else { return }
        chat.messages.removeSubrange(index...)
        chat.messages.append(ChatMessage(body: .assistant(AssistantTurn())))
        pruneInvalidatedCompactionAfterRewind()
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
        guard !isCompacting, !isRunning, let throughIndex = compactableRangeEndIndex else { return }
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
                do {
                    for try await chunk in stream {
                        if let d = chunk.contentDelta { acc += d }
                    }
                } catch {}
                let trimmed = acc.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.count >= 80 {
                    aiSummary = trimmed
                }
            }
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
        chat.compactedThroughMessageID = chat.messages[throughIndex].id
        appendNotice("Compacted \(slice.count) older messages into structured session memory (keeping the latest \(chat.messages.count - 1 - throughIndex) messages verbatim). Tap the Context ring anytime to restore full memory.")
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
            workspace = nil
            changeSession = nil
            appendNotice("Closed the pull request and removed its side branch.")
        } catch { appendNotice("Couldn't throw it away: \(app.github.describe(error))") }
    }

    func undoLastSave() async {
        guard let app, let github = app.github.client, var receipts = chat.saveReceipts,
              let index = receipts.lastIndex(where: { $0.undoneAt == nil }) else { return }
        do {
            let undoReceipt = try await GitHubChangeService(github: github).undo(receipts[index])
            receipts[index].undoneAt = Date()
            chat.saveReceipts = receipts
            if let existingWorkspace = workspace {
                let advanced = existingWorkspace.advancing(toCommit: undoReceipt.savedCommit)
                workspace = advanced
                if let existingChanges = changeWorkspace {
                    changeWorkspace = await existingChanges.rebased(onto: advanced)
                }
            } else {
                workspace = nil
            }
            changeSession = nil
            appendNotice("Undid MAIPA-G's last save.")
        } catch { appendNotice("Undo stopped safely: \(app.github.describe(error))") }
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
        let grace = BackgroundGrace(name: "MAIPA-G reply") { [weak self] in self?.suspendForBackgroundIfNeeded() }
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
        defer {
            isRunning = false
            run = nil
            saveSoon(immediately: true)
            app?.turnFinished(in: self)
        }
        guard let app else { return }
        guard app.openRouter.isSignedIn else {
            fail(.signInNeeded, "Connect an AI provider (OpenRouter, OneProvider, SayGM, TeamoRouter, or OmniRoute) in Settings first.")
            return
        }
        await app.connectors.reconnectIfNeeded()
        let aiClient = app.openRouter.client
        let hasOpenRouter = app.openRouter.hasOpenRouterKey

        let lastMessage = chat.messages.last { $0.userText != nil }?.userText ?? ""
        if case .model(let pickedID) = chat.model,
           let pickedModel = app.openRouter.modelsByID[pickedID],
           pickedModel.isPureImageModel {
            await runPureImageTurn(model: pickedModel, prompt: lastMessage, client: aiClient, app: app)
            return
        }
        let changeAuthorization = ChangeAuthorization(request: lastMessage)
        let allAttachments = chat.messages.flatMap { message -> [AttachmentReference] in
            if case .user(let user) = message.body { return user.attachments }
            return []
        }
        var attachmentData: [UUID: Data] = [:]
        for attachment in allAttachments where attachment.kind == .image || attachment.kind == .pdf {
            guard attachment.bytes <= 32 * 1_048_576,
                  let raw = try? await app.attachmentStore.data(for: attachment) else { continue }
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
            let readOtherRepoTool = ReadOtherRepositoryFileTool(github: github, repositories: app.github.repos)
            tools.append(CreateRepositoryTool(github: github))
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
            guard let github = app.github.client else {
                fail(.signInNeeded, "Connect GitHub so MAIPA-G can read \(repo.ref.fullName).")
                return
            }
            do {
                var activeReceipt = (chat.saveReceipts ?? []).last { $0.repo == repo.ref && $0.pullRequest != nil && $0.resolution == nil }
                if let candidate = activeReceipt, let pull = candidate.pullRequest {
                    if let current = try? await github.pullRequest(repo.ref, number: pull.number), current.state != "open" {
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
                let commit = try await github.resolveCommit(repo.ref, ref: workingBranch)
                let workspace = workspaceFor(repo: workingRepo, commit: commit, github: github, store: app.snapshots)
                await workspace.prefetch()
                let changes: ChangeWorkspace
                if let existing = changeWorkspace {
                    if existing.base.commit == commit && existing.base.repo == workspace.repo {
                        changes = existing
                    } else if existing.base.repo == workspace.repo {
                        let rebased = await existing.rebased(onto: workspace)
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
                let service = GitHubChangeService(github: github)
                let rules = await service.resolveRules(in: workspace, directSaveSetting: app.settings.savesDirectly(to: repo.ref))
                let loadedHooks = await RepoHooks.load(from: workspace)
                repoHooks = loadedHooks.hooks
                hookProblems = loadedHooks.problems
                repoLocalAgents = await RepoAgentLoader.loadAgents(from: workspace)
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
        let computerNote = await prepareComputer(app: app, repo: repoContext, lastUserMessage: lastMessage, isAutonomous: autonomous && app.settings.autonomousEnabled)
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
            let repoHome = repoContext.map { "repos/\($0.ref.owner)/\($0.ref.name)" }
            tools.append(RunCommandTool(control: control, homePath: repoHome))
            tools.append(ComputerTaskTool(control: control, homePath: repoHome))
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
            tools.append(GenerateImageTool(client: aiClient, store: app.attachmentStore, model: imageModel.id, maySpend: !imageModel.isFree))
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
                    } else if helperChoice == .auto, invocation.definition.modelPolicy == .differentFromPrimary {
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
                tools.append(inspectWorkflowTool)
                tools.append(UpdateWorkflowTool { [weak self] runID, replacementSteps in
                    guard let self else { throw ToolInputError("Chat is no longer open.") }
                    return try await self.replaceRemainingWorkflowSteps(runID: runID, steps: replacementSteps)
                })
            }
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
                isAutonomous: isAutonomousTurn
            ),
            tools: tools,
            allowTools: app.openRouter.supportsTools(chat.model),
            spendLimit: app.settings.spendLimitOn ? app.settings.spendLimit : nil,
            attachmentData: attachmentData,
            serverTools: [],
            fallbackModels: fallbackModels,
            requiresInitialSpendApproval: false,
            steering: turnSteering
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
        for await event in run.events {
            guard case .updated(let turn, let milestone) = event else { continue }
            receive(turn, milestone: milestone)
        }
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
        chat.updatedAt = Date()
        await nameChatIfNeeded()
    }

    /// Streamed updates are drawn at most every 45 ms; finished steps and tools at once.
    private func receive(_ turn: AssistantTurn, milestone: Bool) {
        if !pendingSteers.isEmpty {
            let consumed = Set(turn.steps.flatMap { $0.steeredMessages ?? [] })
            if !consumed.isEmpty {
                pendingSteers.removeAll { consumed.contains($0) }
            }
        }
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
            try? await Task.sleep(nanoseconds: 45_000_000)
            self?.flush()
        }
    }

    private func flush() {
        flushScheduled = false
        if let turn = pendingTurn {
            pendingTurn = nil
            replaceLastTurn(turn)
            if Date().timeIntervalSince(lastSaved) >= 4.0 {
                chat.updatedAt = Date()
                saveSoon()
            }
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
        client: OpenRouterClient,
        app: AppModel
    ) async {
        let cleanPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanPrompt.isEmpty else {
            fail(.other, "Describe the picture you want \(model.shortName) to generate.")
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
            let generated = try await client.generateImages(
                prompt: cleanPrompt,
                model: model.id,
                options: ImageGenerationOptions(aspectRatio: .square, quality: .standard),
                progress: { _ in }
            )
            var savedResults: [GeneratedImageResult] = []
            for image in generated {
                let ext = image.mimeType.contains("jpeg") || image.mimeType.contains("jpg") ? "jpg" : (image.mimeType.contains("webp") ? "webp" : "png")
                let ref = try await app.attachmentStore.importGeneratedImage(
                    image.data,
                    name: "picture-\(image.id.uuidString.lowercased()).\(ext)",
                    mimeType: image.mimeType
                )
                let item = GeneratedImageResult(
                    attachment: ref,
                    prompt: image.prompt,
                    model: image.model,
                    aspectRatio: ImageAspectRatio.square.rawValue,
                    quality: ImageQuality.standard.rawValue,
                    cost: image.cost
                )
                try? await app.attachmentStore.saveGeneratedMetadata(item)
                savedResults.append(item)
            }
            var turn = lastTurn ?? AssistantTurn()
            var finishedStep = AssistantStep()
            finishedStep.model = model.id
            finishedStep.text = savedResults.isEmpty ? "No picture was returned by \(model.shortName)." : "Generated with **\(model.shortName)**."
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

    private func upsertWorkflowSnapshot(_ snapshot: ActiveWorkflowRunSnapshot) {
        if let idx = activeWorkflowRuns.firstIndex(where: { $0.id == snapshot.id }) {
            activeWorkflowRuns[idx] = snapshot
        } else {
            activeWorkflowRuns.insert(snapshot, at: 0)
        }
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
            throw ToolInputError("No active workflow run found to update.")
        }
        let updated = try await engine.replaceRemainingSteps(steps)
        let cp = await engine.state
        if let idx = activeWorkflowRuns.firstIndex(where: { $0.id == targetID }) {
            activeWorkflowRuns[idx].definition = updated
            activeWorkflowRuns[idx].checkpoint = cp
        }
        return "Updated workflow `\(updated.name)` (`\(targetID)`): now \(updated.steps.count) total top-level steps."
    }

    // UI Controls for Inline `ACTIVE WORKFLOWS` Tree Card & `Workstation` `Workflows` Tab

    func pauseWorkflowRun(_ runID: String) {
        guard let engine = workflowEngines[runID] else { return }
        Task { await engine.requestPause() }
    }

    func stopWorkflowRun(_ runID: String) {
        workflowTasks[runID]?.cancel()
        workflowTasks[runID] = nil
        guard let engine = workflowEngines[runID] else { return }
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
                }
            }
        }
    }

    func setWorkflowRunModel(_ runID: String, modelID: String, effort: ThinkingLevel? = nil) {
        guard modelID != ModelChoice.freeID, let engine = workflowEngines[runID] else { return }
        Task {
            try? await engine.setDefaultModel(modelID, effort: effort)
            let cp = await engine.state
            await MainActor.run {
                if let idx = self.activeWorkflowRuns.firstIndex(where: { $0.id == runID }) {
                    self.activeWorkflowRuns[idx].checkpoint = cp
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
        guard let snap = activeWorkflowRuns.first(where: { $0.id == runID }), !snap.isRunning, let app else { return }
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
