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

    init(_ chat: Chat) {
        id = chat.id
        title = chat.title.isEmpty ? "New chat" : chat.title
        createdAt = chat.createdAt
        updatedAt = chat.updatedAt
        repoName = chat.repo?.ref.fullName
        preview = chat.preview
        firstMessage = chat.firstUserText ?? ""
        groupID = chat.groupID
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

    func load() async {
        let chats = await store.loadAll()
        var loadedSummaries = chats.map(ChatSummary.init)
        for index in chats.indices where chats[index].lastAssistantTurn?.status == .running {
            let chat = chats[index]
            let session = ChatSession(
                chat: chat,
                app: app,
                draft: await store.loadDocument(ComposerDraft.self, at: ComposerDraft.path(for: chat.id.uuidString.lowercased()))
            )
            session.settleInterruptedTurnOnLaunch()
            sessions[chat.id] = session
            loadedSummaries[index] = ChatSummary(session.chat)
        }
        summaries = loadedSummaries.sorted { $0.updatedAt > $1.updatedAt }
        isLoaded = true
    }

    /// After a save brought chats from GitHub: refreshes the list, and any open chat that isn't busy
    /// while preserving unsaved staged repository changes, active workflows, and Composer drafts.
    func reloadFromDisk() async {
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
                        fresh.settleInterruptedTurnOnLaunch()
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
                settled.settleInterruptedTurnOnLaunch()
                sessions[chat.id] = settled
                resolvedChats[index] = settled.chat
            }
        }
        summaries = resolvedChats.map(ChatSummary.init).sorted { $0.updatedAt > $1.updatedAt }
        let ids = Set(chats.map(\.id))
        if let open = openSession, !ids.contains(open.id), !open.isRunning, !open.hasActiveWorkflowRuns, !open.chat.messages.isEmpty {
            let hasUnsaved = await open.hasUnsavedStagedWork()
            if !hasUnsaved {
                openSession = nil
            }
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
        session.settleInterruptedTurnOnLaunch()
        sessions[id] = session
        openSession = session
        dropIdleSessions()
    }

    /// Starts a chat from the home screen's box.
    func startChat(text: String, attachments: [AttachmentReference] = [], repo: ChatRepo?, model: ModelChoice, thinking: ThinkingLevel, groupID: UUID? = nil, memories: [String] = [], autonomous: Bool = false) {
        let chat = Chat(repo: repo, model: model, thinking: thinking, groupID: groupID, memoryContext: memories)
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

    func suspendAllForBackground() {
        for session in sessions.values where session.isRunning {
            session.suspendForBackgroundIfNeeded()
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
        } catch {
            return
        }
        upsert(chat)
        // Local disk is saved immediately; while a turn is actively streaming, debounce remote GitHub
        // commits so MAIPA-G-data isn't hammered every 4 seconds (and doesn't hold Saving… continuously).
        let isActivelyStreaming = sessions[chat.id]?.isRunning == true
        app?.sync.request(after: isActivelyStreaming ? 25 : 3.5)
    }

    private func upsert(_ chat: Chat) {
        guard !chat.messages.isEmpty else { return }
        let summary = ChatSummary(chat)
        if let index = summaries.firstIndex(where: { $0.id == chat.id }) {
            summaries[index] = summary
        } else {
            summaries.append(summary)
        }
        summaries.sort { $0.updatedAt > $1.updatedAt }
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
