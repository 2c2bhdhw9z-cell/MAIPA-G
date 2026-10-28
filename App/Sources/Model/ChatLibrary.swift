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

    init(_ chat: Chat) {
        id = chat.id
        title = chat.title.isEmpty ? "New chat" : chat.title
        createdAt = chat.createdAt
        updatedAt = chat.updatedAt
        repoName = chat.repo?.ref.fullName
        preview = chat.preview
        firstMessage = chat.firstUserText ?? ""
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
        var fixed: [Chat] = []
        for var chat in chats {
            // A reply that was mid-way when the app last closed can't carry on by itself.
            if var turn = chat.lastAssistantTurn, turn.status == .running {
                turn.status = .stopped
                turn.notices.append("The app closed before this reply finished.")
                for stepIndex in turn.steps.indices {
                    for callIndex in turn.steps[stepIndex].toolCalls.indices where turn.steps[stepIndex].toolCalls[callIndex].status == .running {
                        turn.steps[stepIndex].toolCalls[callIndex].status = .failed
                    }
                    if turn.steps[stepIndex].finishedAt == nil { turn.steps[stepIndex].finishedAt = Date() }
                }
                chat.messages[chat.messages.count - 1].assistantTurn = turn
                fixed.append(chat)
            }
        }
        for chat in fixed { try? await store.save(chat) }
        let fixedIDs = Dictionary(fixed.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        summaries = chats.map { ChatSummary(fixedIDs[$0.id] ?? $0) }.sorted { $0.updatedAt > $1.updatedAt }
        isLoaded = true
    }

    /// After a save brought chats from GitHub: refreshes the list, and any open chat that isn't busy.
    func reloadFromDisk() async {
        let chats = await store.loadAll()
        summaries = chats.map(ChatSummary.init).sorted { $0.updatedAt > $1.updatedAt }
        for chat in chats {
            if let session = sessions[chat.id], !session.isRunning, chat.updatedAt > session.chat.updatedAt {
                sessions[chat.id] = ChatSession(chat: chat, app: app)
                if openSession?.id == chat.id { openSession = sessions[chat.id] }
            }
        }
        let ids = Set(chats.map(\.id))
        if let open = openSession, !ids.contains(open.id), !open.isRunning, !open.chat.messages.isEmpty {
            openSession = nil
        }
    }

    // MARK: Opening

    func open(_ id: UUID) async {
        if let session = sessions[id] {
            openSession = session
            return
        }
        guard let chat = await store.load(id) else { return }
        let session = ChatSession(chat: chat, app: app)
        sessions[id] = session
        openSession = session
        dropIdleSessions()
    }

    /// Starts a chat from the home screen's box.
    func startChat(text: String, repo: ChatRepo?, model: ModelChoice, thinking: ThinkingLevel) {
        let chat = Chat(repo: repo, model: model, thinking: thinking)
        let session = ChatSession(chat: chat, app: app)
        sessions[chat.id] = session
        openSession = session
        session.send(text)
        upsert(session.chat)
        dropIdleSessions()
    }

    func showHome() {
        openSession = nil
        dropIdleSessions()
    }

    /// Frees memory from chats that are neither on screen nor working.
    private func dropIdleSessions() {
        for (id, session) in sessions where session.id != openSession?.id && !session.isRunning {
            sessions[id] = nil
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
        app?.sync.request()
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
        sessions[id]?.stop()
        sessions[id] = nil
        if openSession?.id == id { openSession = nil }
        await store.delete(id)
        summaries.removeAll { $0.id == id }
        app?.sync.request()
    }

    func session(_ id: UUID) -> ChatSession? { sessions[id] }

    var runningCount: Int { sessions.values.filter(\.isRunning).count }
}
