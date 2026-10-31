import AgentCore
import SwiftUI

/// An open chat: the conversation, Workstation access, and the message box at the bottom.
struct ChatScreen: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @Environment(\.openURL) private var openURL
    @Bindable var session: ChatSession

    @State private var followsBottom = true
    @State private var scrollPosition = ScrollPosition(edge: .bottom)
    @State private var renaming = false
    @State private var newTitle = ""
    @State private var editingMessageID: UUID?
    @State private var editedMessageText = ""
    @State private var showingDiff = false

    private let bottomID = "chat-bottom-anchor"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                let messages = session.chat.messages
                LazyVStack(alignment: .leading, spacing: 20) {
                    messageRows(messages)
                    Color.clear
                        .frame(height: 10)
                        .id(bottomID)
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 8)
                .animation(theme.messagesSlideIn ? .snappy : nil, value: session.chat.messages.count)
            }
            .scrollPosition($scrollPosition)
            .scrollDismissesKeyboard(.interactively)
            .modifier(BottomScrollTrackingModifier(followsBottom: $followsBottom))
            .onAppear {
                followsBottom = true
                scrollToBottomWithoutAnimation(proxy)
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 90_000_000)
                    if followsBottom { scrollToBottomWithoutAnimation(proxy) }
                }
            }
            .onChange(of: contentSize) { _, _ in
                if followsBottom { scrollToBottomWithoutAnimation(proxy) }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                topBar
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                bottomInset(proxy: proxy)
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .alert("Checks did not pass", isPresented: Binding(get: { session.mergeWarning != nil }, set: { if !$0 { session.cancelMergeWarning() } })) {
            Button("Add it anyway", role: .destructive) { Task { await session.addLastSave(force: true) } }
            Button("Cancel", role: .cancel) { session.cancelMergeWarning() }
        } message: { Text(session.mergeWarning ?? "") }
        .sheet(isPresented: $showingDiff) { ChangesDiffScreen(session: session) }
        .alert("Edit and resend", isPresented: Binding(get: { editingMessageID != nil }, set: { if !$0 { editingMessageID = nil } })) {
            TextField("Message", text: $editedMessageText, axis: .vertical)
            Button("Resend") {
                guard let id = editingMessageID else { return }
                editingMessageID = nil
                session.editAndResend(id, text: editedMessageText)
            }
            Button("Cancel", role: .cancel) { editingMessageID = nil }
        }
        .alert("Rename chat", isPresented: $renaming) {
            TextField("Name", text: $newTitle)
            Button("Save") { session.rename(newTitle) }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: - Lowered Custom Top Bar (Crisp in Light & Dark Mode)

    private var topBar: some View {
        HStack(spacing: 10) {
            MenuButton()

            Spacer(minLength: 4)

            Button {
                newTitle = session.chat.title
                renaming = true
            } label: {
                VStack(spacing: 1) {
                    Text(session.chat.title.isEmpty ? "New chat" : session.chat.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if session.isRunning {
                        Text("Working…")
                            .font(.caption2)
                            .foregroundStyle(Theme.secondaryText)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: 220, minHeight: 40)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Rename this chat")

            Spacer(minLength: 4)

            HStack(spacing: 4) {
                if let cost = session.chat.totalUsage.cost {
                    Text(cost.dollars)
                        .font(.caption.weight(.medium).monospacedDigit())
                        .foregroundStyle(Theme.secondaryText)
                        .padding(.leading, 8)
                        .padding(.trailing, 2)
                }

                Button {
                    app.sheet = .workstation(.chat(session.id), hasPendingSave ? .changes : .canvas)
                } label: {
                    Image(systemName: "square.on.square.dashed")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(theme.accent)
                        .frame(width: 40, height: 40)
                        .contentShape(Rectangle())
                        .overlay(alignment: .topTrailing) {
                            if hasPendingSave {
                                Circle()
                                    .fill(theme.accent)
                                    .frame(width: 7, height: 7)
                                    .offset(x: -5, y: 6)
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Workstation")

                Button {
                    app.newChat()
                } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(theme.accent)
                        .frame(width: 40, height: 40)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("New chat")
            }
            .padding(.horizontal, 4)
            .glassPanel(cornerRadius: 22, interactive: false)
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .padding(.bottom, 6)
        .background {
            ZStack(alignment: .bottom) {
                Rectangle()
                    .fill(.ultraThinMaterial)
                Theme.background.opacity(0.82)
                Rectangle()
                    .fill(Theme.stroke)
                    .frame(height: 0.5)
            }
            .ignoresSafeArea(edges: .top)
        }
    }

    private var hasPendingSave: Bool {
        guard let receipt = session.chat.saveReceipts?.last else { return false }
        return receipt.resolution == nil && receipt.undoneAt == nil
    }

    // MARK: - Bottom Inset (`↓` Jump Button + Solid Save Banner + Composer)

    private func bottomInset(proxy: ScrollViewProxy) -> some View {
        VStack(spacing: 8) {
            if !followsBottom {
                HStack {
                    Spacer()
                    Button {
                        jumpToBottom(proxy)
                    } label: {
                        Image(systemName: "arrow.down")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.primary)
                            .frame(width: 44, height: 44)
                            .glassPanel(cornerRadius: 22, interactive: false)
                            .contentShape(Circle())
                            .shadow(color: .black.opacity(0.16), radius: 8, y: 3)
                    }
                    .buttonStyle(.plain)
                    .contentShape(Circle())
                    .padding(.trailing, 16)
                    .accessibilityLabel("Jump to the newest")
                }
                .transition(.scale.combined(with: .opacity))
            }

            VStack(spacing: 8) {
                if let receipt = session.chat.saveReceipts?.last,
                   (receipt.pullRequest != nil && receipt.resolution == nil) || (receipt.undoneAt == nil && receipt.resolution == nil) {
                    HStack(spacing: 8) {
                        if receipt.pullRequest != nil, receipt.resolution == nil {
                            Button("Add it") { Task { await session.addLastSave() } }
                                .buttonStyle(.borderedProminent)
                                .buttonBorderShape(.capsule)
                            Button("Throw away", role: .destructive) { Task { await session.throwAwayLastSave() } }
                                .buttonStyle(.bordered)
                                .buttonBorderShape(.capsule)
                        }
                        if receipt.undoneAt == nil, receipt.resolution == nil {
                            Button("Undo") { Task { await session.undoLastSave() } }
                                .buttonStyle(.bordered)
                                .buttonBorderShape(.capsule)
                        }
                        if let status = session.mergeCheckStatus {
                            Text(status)
                                .font(.caption)
                                .foregroundStyle(status == "Checks passed" || status == "No automatic checks" ? .green : .orange)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        Button {
                            app.sheet = .workstation(.chat(session.id), .changes)
                        } label: {
                            Label("Diff", systemImage: "doc.text.magnifyingglass")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(theme.accent)
                        }
                        .buttonStyle(.plain)
                    }
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.stroke))
                    .padding(.horizontal, 12)
                }

                Composer(
                    text: $session.draft,
                    attachments: $session.draftAttachments,
                    webEnabled: $session.webEnabled,
                    autonomous: $session.autonomous,
                    modelLabel: app.openRouter.label(for: session.chat.model),
                    contextUsedTokens: session.contextUsedTokens,
                    contextLimitTokens: app.openRouter.contextLimit(for: session.chat.model, lastModelID: session.contextModelID),
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
                        jumpToBottom(proxy)
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
                    onPreview: { if let repo = session.chat.repo { app.sheet = .webPreview(repo) } },
                    onFiles: { if let repo = session.chat.repo { app.sheet = .files(repo, .chat(session.id)) } },
                    onWorkstation: { app.sheet = .workstation(.chat(session.id)) },
                    canCompact: session.canCompact,
                    onCompact: { session.compact() }
                )
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
            }
            .padding(.top, 6)
            .background {
                LinearGradient(
                    colors: [Theme.background.opacity(0), Theme.background.opacity(0.95), Theme.background],
                    startPoint: .top,
                    endPoint: UnitPoint(x: 0.5, y: 0.22)
                )
                .ignoresSafeArea()
            }
        }
    }

    @ViewBuilder
    private func messageRows(_ messages: [ChatMessage]) -> some View {
        ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
            if shouldShowTimestampHeader(at: index, in: messages) {
                Text(MessageTimestampFormatter.sectionHeader(message.createdAt))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Theme.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 2)
            }

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
    }

    private func shouldShowTimestampHeader(at index: Int, in messages: [ChatMessage]) -> Bool {
        guard messages.indices.contains(index) else { return false }
        if index == 0 { return true }
        let prev = messages[index - 1].createdAt
        let curr = messages[index].createdAt
        return curr.timeIntervalSince(prev) >= 20 * 60
    }

    private func jumpToBottom(_ proxy: ScrollViewProxy) {
        Haptics.selection()
        followsBottom = true
        withAnimation(.snappy(duration: 0.25)) {
            scrollPosition.scrollTo(edge: .bottom)
            proxy.scrollTo(bottomID, anchor: .bottom)
        }
        // Second pass after LazyVStack settles offscreen row heights so one tap always lands flush at bottom.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard followsBottom else { return }
            withAnimation(.snappy(duration: 0.16)) {
                scrollPosition.scrollTo(edge: .bottom)
                proxy.scrollTo(bottomID, anchor: .bottom)
            }
        }
    }

    private func scrollToBottomWithoutAnimation(_ proxy: ScrollViewProxy) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            scrollPosition.scrollTo(edge: .bottom)
            proxy.scrollTo(bottomID, anchor: .bottom)
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
        let base = id.split(separator: "/").last.map(String.init) ?? id
        let plain = base.split(separator: ":").first.map(String.init) ?? base
        let shouted: Set<String> = ["gpt", "glm", "ai", "llm", "qwq", "oss", "vl"]
        return plain.split(separator: "-").map { word in
            if shouted.contains(word.lowercased()) { return word.uppercased() }
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
            retryAnswer: { session.retryAnswer($0) },
            editMessage: { id, text in
                editingMessageID = id
                editedMessageText = text
            },
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

private struct BottomScrollTrackingModifier: ViewModifier {
    @Binding var followsBottom: Bool

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content
                .onScrollGeometryChange(for: Bool.self) { geo in
                    let visibleBottom = geo.contentOffset.y + geo.containerSize.height - geo.contentInsets.bottom
                    let remaining = geo.contentSize.height - visibleBottom
                    return remaining <= 80
                } action: { _, nearBottom in
                    if nearBottom != followsBottom {
                        followsBottom = nearBottom
                    }
                }
        } else {
            content
                .simultaneousGesture(
                    DragGesture(minimumDistance: 12).onChanged { value in
                        if value.translation.height > 16 { followsBottom = false }
                    }
                )
        }
    }
}
