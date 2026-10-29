import AgentCore
import SwiftUI

/// An open chat: the conversation, and the message box at the bottom.
struct ChatScreen: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @Environment(\.openURL) private var openURL
    @Bindable var session: ChatSession

    @State private var followsBottom = true
    @State private var renaming = false
    @State private var newTitle = ""

    private let bottomID = "bottom"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    let messages = session.chat.messages
                    ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                        MessageRow(
                            message: message,
                            isLatest: index == messages.count - 1,
                            modelName: modelName,
                            actions: actions
                        )
                        .equatable()
                        .id(message.id)
                        .transition(theme.messagesSlideIn ? AnyTransition.move(edge: .bottom).combined(with: .opacity) : AnyTransition.identity)
                    }
                    Color.clear.frame(height: 1).id(bottomID)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .animation(theme.messagesSlideIn ? .snappy : nil, value: session.chat.messages.count)
            }
            .scrollDismissesKeyboard(.immediately)
            .defaultScrollAnchor(.bottom)
            .simultaneousGesture(
                DragGesture(minimumDistance: 12).onChanged { value in
                    // Scrolling up to read stops the chat jumping to the newest words.
                    if value.translation.height > 16 { followsBottom = false }
                }
            )
            .onChange(of: contentSize) { _, _ in
                if followsBottom { proxy.scrollTo(bottomID, anchor: .bottom) }
            }
            .overlay(alignment: .bottomTrailing) {
                if !followsBottom {
                    Button {
                        followsBottom = true
                        withAnimation(.snappy) { proxy.scrollTo(bottomID, anchor: .bottom) }
                    } label: {
                        Image(systemName: "arrow.down")
                            .font(.subheadline.weight(.bold))
                            .frame(width: 38, height: 38)
                            .glassPanel(cornerRadius: 19, interactive: true)
                    }
                    .buttonStyle(.plain)
                    .padding(16)
                    .accessibilityLabel("Jump to the newest")
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 4) {
                    if let receipt = session.chat.saveReceipts?.last {
                        HStack(spacing: 10) {
                            if receipt.pullRequest != nil, receipt.resolution == nil {
                                Button("Add it") { Task { await session.addLastSave() } }.buttonStyle(.borderedProminent)
                                Button("Throw away", role: .destructive) { Task { await session.throwAwayLastSave() } }.buttonStyle(.bordered)
                            }
                            if receipt.undoneAt == nil, receipt.resolution == nil {
                                Button("Undo") { Task { await session.undoLastSave() } }.buttonStyle(.bordered)
                            }
                            Spacer()
                        }
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 16)
                    }
                    Composer(
                    text: $session.draft,
                    attachments: $session.draftAttachments,
                    webEnabled: $session.webEnabled,
                    autonomous: $session.autonomous,
                    modelLabel: app.openRouter.label(for: session.chat.model),
                    thinking: session.chat.thinking,
                    thinkingLevels: app.openRouter.thinkingLevels(for: session.chat.model),
                    repo: session.chat.repo,
                    groupName: app.groups.name(for: session.chat.groupID),
                    isGitHubConnected: app.github.isConnected,
                    isRunning: session.isRunning,
                    canStop: true,
                    onSend: {
                        let text = session.draft
                        let attachments = session.draftAttachments
                        session.draft = ""
                        session.draftAttachments = []
                        followsBottom = true
                        session.send(text, attachments: attachments)
                        Haptics.tap()
                    },
                    onStop: { session.stop() },
                    onPickModel: { app.sheet = .models(.chat(session.id)) },
                    onPickThinking: { session.setThinking($0) },
                    onPickRepo: { app.sheet = app.github.isConnected ? .repos(.chat(session.id)) : .connectGitHub },
                    onPickBranch: { app.sheet = .branches(.chat(session.id)) },
                    onClearRepo: { session.setRepo(nil) },
                    onPickGroup: { app.sheet = .groups(.chat(session.id)) },
                    onSpec: { app.sheet = .specs(session.chat.repo) },
                    onPicture: { app.sheet = .pictureGenerator(.chat(session.id)) },
                    onPreview: { if let repo = session.chat.repo { app.sheet = .webPreview(repo) } }
                )
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
                .padding(.top, 4)
                .background(alignment: .bottom) {
                    LinearGradient(colors: [Theme.background.opacity(0), Theme.background], startPoint: .top, endPoint: .center)
                        .ignoresSafeArea()
                }
                }
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { MenuButton() }
            ToolbarItem(placement: .principal) {
                Button {
                    newTitle = session.chat.title
                    renaming = true
                } label: {
                    VStack(spacing: 0) {
                        Text(session.chat.title.isEmpty ? "New chat" : session.chat.title)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        if session.isRunning {
                            Text("Working…").font(.caption2).foregroundStyle(Theme.secondaryText)
                        }
                    }
                    .frame(maxWidth: 240)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Rename this chat")
            }
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 12) {
                    if let cost = session.chat.totalUsage.cost { Text(cost.dollars).font(.caption.monospacedDigit()).foregroundStyle(Theme.secondaryText) }
                    if let repo = session.chat.repo {
                        Button { app.sheet = .files(repo, .chat(session.id)) } label: { Image(systemName: "folder") }
                            .accessibilityLabel("Files")
                    }
                    Button { app.newChat() } label: { Image(systemName: "square.and.pencil") }
                        .accessibilityLabel("New chat")
                }
            }
        }
        .alert("Rename chat", isPresented: $renaming) {
            TextField("Name", text: $newTitle)
            Button("Save") { session.rename(newTitle) }
            Button("Cancel", role: .cancel) {}
        }
    }

    /// Changes whenever the conversation grows, to keep the newest words in view.
    private var contentSize: Int {
        let messages = session.chat.messages
        var size = messages.count * 1_000_003
        if let turn = messages.last?.assistantTurn {
            for step in turn.steps {
                size += step.text.count + step.reasoning.count / 4 + step.toolCalls.count * 7
            }
            if turn.pendingQuestions != nil { size += 11 }
            if turn.failure != nil { size += 13 }
        }
        return size
    }

    private func modelName(_ id: String) -> String {
        if let name = app.openRouter.modelsByID[id]?.shortName { return name }
        // Not in the list (yet): "anthropic/claude-sonnet-5.5:free" reads as "Claude Sonnet 5.5".
        let base = id.split(separator: "/").last.map(String.init) ?? id
        let plain = base.split(separator: ":").first.map(String.init) ?? base
        let shouted: Set<String> = ["gpt", "glm", "ai", "llm", "qwq", "oss", "vl"]
        return plain.split(separator: "-").map { word in
            if shouted.contains(word.lowercased()) { return word.uppercased() }
            // Sizes like "70b", "1.5b" and "8x7b" read as "70B", "1.5B" and "8x7B".
            if word.count > 1, let first = word.first, first.isNumber, let unit = word.last, "bkm".contains(unit),
               word.dropLast().allSatisfy({ $0.isNumber || $0 == "." || $0 == "x" }) {
                return String(word.dropLast()) + String(unit).uppercased()
            }
            return word.first.map { $0.isLetter ? $0.uppercased() + word.dropFirst() : String(word) } ?? ""
        }.joined(separator: " ")
    }

    private var actions: TurnActions {
        TurnActions(
            answer: { session.answer($0) },
            retry: { session.retry() },
            keepGoing: { session.send("Please keep going.") },
            approveSpending: { session.approveMoreSpending() },
            switchToFree: { session.switchToFreeAIs() },
            signIn: {
                if app.openRouter.isSignedIn, !app.github.isConnected {
                    app.sheet = .connectGitHub
                } else {
                    app.sheet = .signInOpenRouter
                }
            },
            openURL: { openURL($0) },
            toggleStar: { session.toggleStar($0) }
        )
    }
}
