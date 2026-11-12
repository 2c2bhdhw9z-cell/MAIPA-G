import AgentCore
import Foundation
import Observation

/// A chat as the side menu lists it.
struct ChatSummary: Identifiable, Hashable, Sendable {
    var id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var repoName: String?
    var preview: String
    var firstMessage: String
    var groupID: UUID?
    /// Where the chat's work is, for the list, the way Kiro shows each session's status.
    enum Activity: Hashable, Sendable { case idle, working, needsYou, done, failed, stopped }
    var activity: Activity
    /// What it's doing right now (the running step), or the start of the last reply.
    var activityLine: String
    var isAutonomous: Bool
    /// A reply is running on the computer, so it's working even with the app closed.
    var runsOnComputer: Bool

    init(_ chat: Chat) {
        id = chat.id
        title = chat.title.isEmpty ? "New chat" : chat.title
        createdAt = chat.createdAt
        updatedAt = chat.updatedAt
        repoName = chat.repo?.ref.fullName
        preview = chat.preview
        firstMessage = chat.firstUserText ?? ""
        groupID = chat.groupID
        isAutonomous = chat.autonomous ?? false
        runsOnComputer = chat.computerRunID != nil
        let turn = chat.lastAssistantTurn
        switch turn?.status {
        case .running?: activity = .working
        case .waitingForUser?: activity = .needsYou
        case .failed?: activity = .failed
        case .stopped?: activity = .stopped
        case .done?: activity = .done
        case nil: activity = .idle
        }
        let running = turn?.steps.last?.toolCalls.last { $0.status == .running }?.summary
        let firstLine = chat.preview.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        activityLine = (activity == .working ? running : nil) ?? firstLine
    }

    func matches(_ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return true }
        return [title, preview, firstMessage, repoName ?? ""].contains { $0.localizedCaseInsensitiveContains(query) }
    }
}

/// All the chats: a light list for the side menu, and full sessions for chats that are open or
/// still working.
@MainActor
@Observable
final class ChatLibrary {
    private(set) var summaries: [ChatSummary] = []
    private(set) var isLoaded = false
    /// The chat on screen, or nil for the home screen.
    private(set) var openSession: ChatSession?

    @ObservationIgnored weak var app: AppModel?
    @ObservationIgnored private var sessions: [UUID: ChatSession] = [:]
    let store: ChatStore

    init(store: ChatStore) {
        self.store = store
    }

    /// Screenshots only: shows these chats, and opens one, without reading or writing any file.
    func preview(summaries: [ChatSummary], open chat: Chat?) {
        self.summaries = summaries
        isLoaded = true
        if let chat {
            let session = ChatSession(chat: chat, app: app)
            sessions[chat.id] = session
            openSession = session
        }
    }

    /// Reads every chat. Replies that were still running when the app closed get their session
    /// here but only carry on in `resumeRunning()`, once connectors and the model list are ready.
    func load() async {
        let chats = await store.loadAll()
        var loadedSummaries = chats.map(ChatSummary.init)
        var interrupted: [UUID] = []
        for index in chats.indices where chats[index].lastAssistantTurn?.status == .running {
            let chat = chats[index]
            let session = ChatSession(
                chat: chat,
                app: app,
                draft: await store.loadDocument(ComposerDraft.self, at: ComposerDraft.path(for: chat.id.uuidString.lowercased()))
            )
            session.settleInterruptedWorkflowRunsOnLaunch()
            sessions[chat.id] = session
            interrupted.append(chat.id)
            loadedSummaries[index] = ChatSummary(session.chat)
        }
        runningAtLaunch = interrupted
        summaries = loadedSummaries.sorted { $0.updatedAt > $1.updatedAt }
        isLoaded = true
    }

    /// Chats `load()` found with a reply still running, waiting for `resumeRunning()`.
    @ObservationIgnored private var runningAtLaunch: [UUID] = []

    /// Carries on the replies that were still running when the app closed (one that just crashed
    /// the app is settled instead; see ChatSession.resumeFromRelaunchIfSafe). The app calls this
    /// once at launch, after connectors and the model list have loaded, so a resumed reply never
    /// starts without them.
    func resumeRunning() async {
        let ids = runningAtLaunch
        runningAtLaunch = []
        for id in ids {
            if let session = sessions[id] {
                session.resumeFromRelaunchIfSafe()
                continue
            }
            // Its session was let go while connectors and models loaded (another chat was opened):
            // read it again, as long as it is still running on disk.
            guard let chat = await store.load(id), chat.lastAssistantTurn?.status == .running else { continue }
            let draft = await store.loadDocument(ComposerDraft.self, at: ComposerDraft.path(for: id.uuidString.lowercased()))
            // Opened again while it was being read.
            if let opened = sessions[id] {
                opened.resumeFromRelaunchIfSafe()
                continue
            }
            let session = ChatSession(chat: chat, app: app, draft: draft)
            sessions[id] = session
            session.resumeFromRelaunchIfSafe()
        }
    }

    /// After a save brought chats from GitHub: refreshes the list, and any open chat that isn't busy
    /// while preserving unsaved staged repository changes, active workflows, and Composer drafts.
    func reloadFromDisk() async {
        /// A chat that came from GitHub still marked running is never run again here: it may be
        /// running on another device, or be a stale copy. A reply running on the chat computer is
        /// followed (that only reads its state); any other is settled, and Retry or Keep going
        /// carries it on when the person wants.
        func adoptSyncedRunningTurn(_ session: ChatSession) {
            if session.hasComputerRun {
                session.resumeFromRelaunchIfSafe()
            } else {
                session.settleInterruptedTurnOnLaunch()
            }
        }
        let chats = await store.loadAll()
        var resolvedChats = chats
        for index in resolvedChats.indices {
            let chat = resolvedChats[index]
            if let session = sessions[chat.id] {
                if session.isRunning || session.hasActiveWorkflowRuns {
                    resolvedChats[index] = session.chat
                    continue
                }
                if chat.updatedAt > session.chat.updatedAt {
                    let hasUnsaved = await session.hasUnsavedStagedWork()
                    if hasUnsaved {
                        session.adoptSyncedChatMetadataPreservingWorkspace(chat)
                        resolvedChats[index] = session.chat
                    } else {
                        let existingDraft = ComposerDraft(text: session.draft, attachments: session.draftAttachments)
                        let savedDraft = await store.loadDocument(ComposerDraft.self, at: ComposerDraft.path(for: chat.id.uuidString.lowercased()))
                        let mergedDraft = existingDraft.isEmpty ? savedDraft : existingDraft
                        let fresh = ChatSession(chat: chat, app: app, draft: mergedDraft)
                        adoptSyncedRunningTurn(fresh)
                        fresh.workstationFiles = session.workstationFiles
                        fresh.activeWorkflowRuns = session.activeWorkflowRuns
                        sessions[chat.id] = fresh
                        if openSession?.id == chat.id { openSession = fresh }
                        resolvedChats[index] = fresh.chat
                    }
                } else {
                    resolvedChats[index] = session.chat
                }
            } else if chat.lastAssistantTurn?.status == .running {
                let savedDraft = await store.loadDocument(ComposerDraft.self, at: ComposerDraft.path(for: chat.id.uuidString.lowercased()))
                let settled = ChatSession(chat: chat, app: app, draft: savedDraft)
                adoptSyncedRunningTurn(settled)
                sessions[chat.id] = settled
                resolvedChats[index] = settled.chat
            }
        }
        summaries = resolvedChats.map { listSummary($0) }.sorted { $0.updatedAt > $1.updatedAt }
        let ids = Set(chats.map(\.id))
        if let open = openSession, !ids.contains(open.id), !open.isRunning, !open.hasActiveWorkflowRuns, !open.chat.messages.isEmpty {
            let hasUnsaved = await open.hasUnsavedStagedWork()
            if !hasUnsaved {
                openSession = nil
            }
        }
    }

    /// The chat's row in the side menu. While a reply runs here, the row keeps the place the
    /// reply's start gave it (ChatSession.listedAtWhileRunning), so it doesn't jump about with every
    /// saved part of the reply; it moves again when the reply ends. The chat's own updatedAt still
    /// changes as the reply saves, which saving to GitHub and the Workstation's live files rely on.
    private func listSummary(_ chat: Chat) -> ChatSummary {
        var summary = ChatSummary(chat)
        if let listed = sessions[chat.id]?.listedAtWhileRunning { summary.updatedAt = listed }
        return summary
    }

    /// Chats with a reply running in this app right now. Observable, unlike `sessions`, so the side
    /// menu's status changes the moment a reply starts or ends.
    private(set) var runningChatIDs: Set<UUID> = []

    /// Called by a session whenever its reply starts or ends.
    func sessionRunningChanged(_ id: UUID, isRunning: Bool) {
        if isRunning {
            runningChatIDs.insert(id)
        } else {
            runningChatIDs.remove(id)
        }
    }

    // MARK: Opening

    func open(_ id: UUID) async {
        if let session = sessions[id] {
            openSession = session
            return
        }
        guard let chat = await store.load(id) else { return }
        let draft = await store.loadDocument(ComposerDraft.self, at: ComposerDraft.path(for: id.uuidString.lowercased()))
        let session = ChatSession(chat: chat, app: app, draft: draft)
        session.resumeFromRelaunchIfSafe()
        sessions[id] = session
        openSession = session
        dropIdleSessions()
    }

    /// Starts a chat from the home screen's box.
    func startChat(text: String, attachments: [AttachmentReference] = [], repo: ChatRepo?, additionalRepos: [ChatRepo] = [], model: ModelChoice, thinking: ThinkingLevel, groupID: UUID? = nil, memories: [String] = [], autonomous: Bool = false) {
        var chat = Chat(repo: repo, model: model, thinking: thinking, groupID: groupID, memoryContext: memories)
        if !additionalRepos.isEmpty { chat.additionalRepos = additionalRepos }
        let session = ChatSession(chat: chat, app: app)
        session.autonomous = autonomous
        sessions[chat.id] = session
        openSession = session
        session.send(text, attachments: attachments)
        upsert(session.chat)
        dropIdleSessions()
    }

    var hasActiveWork: Bool {
        sessions.values.contains { $0.isRunning || $0.hasActiveWorkflowRuns }
    }

    var activeWorkSummary: String? {
        guard let busy = sessions.values.first(where: { $0.isRunning || $0.hasActiveWorkflowRuns }) else { return nil }
        return busy.backgroundStatusSubtitle
    }

    func checkpointActiveSessions() async {
        for session in sessions.values where session.isRunning || session.hasActiveWorkflowRuns {
            await session.checkpointNow()
        }
    }

    func resumePausedChats() {
        for session in sessions.values {
            session.resumeInterruptedTurn()
        }
    }

    func showHome() {
        openSession = nil
        dropIdleSessions()
    }

    /// Frees memory from chats that are neither on screen, working, running a workflow, nor holding unsaved staged repo changes.
    private func dropIdleSessions() {
        for (id, session) in sessions where session.id != openSession?.id && !session.isRunning && !session.hasActiveWorkflowRuns {
            if !session.hasInMemoryWorkToPreserve {
                sessions[id] = nil
            } else {
                Task { @MainActor [weak self] in
                    guard let self, let candidate = self.sessions[id],
                          candidate.id != self.openSession?.id,
                          !candidate.isRunning,
                          !candidate.hasActiveWorkflowRuns else { return }
                    let hasStaged = await candidate.hasUnsavedStagedWork()
                    if !hasStaged && candidate.workstationFiles.isEmpty && candidate.activeWorkflowRuns.isEmpty {
                        self.sessions[id] = nil
                    }
                }
            }
        }
    }

    // MARK: Changes

    func save(_ chat: Chat) async {
        guard !PreviewScenes.isActive else { return }
        do {
            try await store.save(chat)
            unsavedChats[chat.id] = nil
        } catch {
            // Recorded in diagnostics, and tried again with the next save.
            noteFailedSave(chat, error)
            return
        }
        await retryUnsavedChats()
        upsert(chat)
        // Local disk is saved immediately; while a turn is actively streaming, debounce remote GitHub
        // commits so MAIPA-G-data isn't hammered every 4 seconds (and doesn't hold Saving… continuously).
        let isActivelyStreaming = sessions[chat.id]?.isRunning == true
        app?.sync.request(after: isActivelyStreaming ? 25 : 3.5)
    }

    private func upsert(_ chat: Chat) {
        guard !chat.messages.isEmpty else { return }
        let summary = listSummary(chat)
        if let index = summaries.firstIndex(where: { $0.id == chat.id }) {
            summaries[index] = summary
        } else {
            summaries.append(summary)
        }
        summaries.sort { $0.updatedAt > $1.updatedAt }
    }

    /// Chats whose last save to this phone failed, by id. Each failure goes into the diagnostics
    /// log once; every later save (of that chat or any other) tries them again until one works.
    @ObservationIgnored private var unsavedChats: [UUID: Chat] = [:]

    private func noteFailedSave(_ chat: Chat, _ error: Error) {
        if unsavedChats.updateValue(chat, forKey: chat.id) == nil {
            _ = app?.report(error, area: "chats", operation: "save chat", path: ChatStore.relativePath(for: chat.id))
        }
    }

    private func retryUnsavedChats() async {
        for id in Array(unsavedChats.keys) {
            // A chat deleted since stays deleted.
            guard sessions[id] != nil || summaries.contains(where: { $0.id == id }) else {
                unsavedChats[id] = nil
                continue
            }
            guard let latest = sessions[id]?.chat ?? unsavedChats[id] else { continue }
            do {
                try await store.save(latest)
                unsavedChats[id] = nil
            } catch {
                // Still failing: tried again with the next save.
            }
        }
    }

    func rename(_ id: UUID, to title: String) async {
        if let session = sessions[id] {
            session.rename(title)
            return
        }
        guard var chat = await store.load(id) else { return }
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        chat.title = String(clean.prefix(80))
        chat.titleIsCustom = true
        chat.updatedAt = Date()
        await save(chat)
    }

    func delete(_ id: UUID) async {
        let summary = summaries.first { $0.id == id }
        sessions[id]?.stop()
        sessions[id] = nil
        if openSession?.id == id { openSession = nil }
        do {
            try await app?.trash.move(
                id: id,
                kind: .chat,
                title: summary?.title ?? "Chat",
                originalPath: ChatStore.relativePath(for: id)
            )
            try? await store.deleteItem(at: ComposerDraft.path(for: id.uuidString.lowercased()))
            summaries.removeAll { $0.id == id }
            app?.sync.request()
        } catch {
            // Keep the item visible when moving it to Recently Deleted fails.
            await reloadFromDisk()
        }
    }

    func removeGroup(_ groupID: UUID) async {
        _ = try? await store.clearGroup(groupID)
        for session in sessions.values where session.chat.groupID == groupID { session.setGroup(nil) }
        await reloadFromDisk()
    }

    func session(_ id: UUID) -> ChatSession? { sessions[id] }

    func generatedImage(_ id: UUID) -> GeneratedImageResult? {
        openSession?.chat.messages.compactMap(\.assistantTurn).flatMap(\.steps).flatMap { $0.generatedImages ?? [] }.first { $0.id == id }
    }

    var runningCount: Int { sessions.values.filter(\.isRunning).count }
}
