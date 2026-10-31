import AgentCore
import SwiftUI

/// An open chat: the conversation, Workstation access, and the message box at the bottom.
struct ChatScreen: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @Environment(\.openURL) private var openURL
    @Bindable var session: ChatSession

    @State private var followsBottom = true
    @State private var animatedJumpCount = 0
    @State private var instantJumpCount = 0
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
            .scrollDismissesKeyboard(.interactively)
            .modifier(BottomEdgeScrollCompatibilityModifier(bottomID: bottomID, animatedJumpCount: animatedJumpCount, instantJumpCount: instantJumpCount))
            .modifier(BottomScrollTrackingModifier(followsBottom: $followsBottom, messages: session.chat.messages) { anchorID in
                session.savedAnchorMessageID = anchorID
            })
            .onAppear {
                followsBottom = session.savedFollowsBottom
                if session.savedFollowsBottom {
                    scrollToBottomWithoutAnimation(proxy)
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 90_000_000)
                        if followsBottom { scrollToBottomWithoutAnimation(proxy) }
                    }
                } else if let anchor = session.savedAnchorMessageID {
                    var tx = Transaction()
                    tx.disablesAnimations = true
                    withTransaction(tx) {
                        proxy.scrollTo(anchor, anchor: .center)
                    }
                }
            }
            .onChange(of: followsBottom) { _, newValue in
                session.savedFollowsBottom = newValue
                if newValue { session.savedAnchorMessageID = nil }
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
                if !session.queuedSteering.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.turn.down.right")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(theme.accent)
                        Text("Queued next: \(session.queuedSteering.last?.text ?? "Attachment")")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Button("Send now") {
                            session.interruptWithQueuedSteering()
                        }
                        .font(.caption.weight(.semibold))
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.capsule)
                        Button {
                            session.clearQueuedSteering()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(Theme.secondaryText)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Cancel queued message")
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.stroke))
                    .padding(.horizontal, 12)
                }

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
                    isCompacting: session.isCompacting,
                    canRestoreMemory: session.canUncompact,
                    onCompact: { session.compact() },
                    onRestoreMemory: { session.restoreFullMemory() }
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
        animatedJumpCount += 1
        withAnimation(.snappy(duration: 0.25)) {
            proxy.scrollTo(bottomID, anchor: .bottom)
        }
        // Second pass after LazyVStack settles offscreen row heights so one tap always lands flush at bottom.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard followsBottom else { return }
            animatedJumpCount += 1
            withAnimation(.snappy(duration: 0.16)) {
                proxy.scrollTo(bottomID, anchor: .bottom)
            }
        }
    }

    private func scrollToBottomWithoutAnimation(_ proxy: ScrollViewProxy) {
        instantJumpCount += 1
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
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
        app.openRouter.displayName(forModelID: id)
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

private struct BottomEdgeScrollCompatibilityModifier: ViewModifier {
    let bottomID: String
    let animatedJumpCount: Int
    let instantJumpCount: Int

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.modifier(BottomEdgeScrollDriver(bottomID: bottomID, animatedJumpCount: animatedJumpCount, instantJumpCount: instantJumpCount))
        } else {
            content
        }
    }
}

@available(iOS 18.0, *)
private struct BottomEdgeScrollDriver: ViewModifier {
    let bottomID: String
    let animatedJumpCount: Int
    let instantJumpCount: Int
    @State private var scrollPosition = ScrollPosition(idType: String.self)

    func body(content: Content) -> some View {
        content
            .scrollPosition($scrollPosition)
            .onChange(of: animatedJumpCount) { _, _ in
                withAnimation(.snappy(duration: 0.22)) {
                    scrollPosition.scrollTo(edge: .bottom)
                }
            }
            .onChange(of: instantJumpCount) { _, _ in
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    scrollPosition.scrollTo(edge: .bottom)
                }
            }
    }
}

private struct BottomScrollTrackingModifier: ViewModifier {
    @Binding var followsBottom: Bool
    var messages: [ChatMessage]
    var onAnchorChange: (UUID?) -> Void

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content
                .onScrollGeometryChange(for: Int.self) { geo in
                    guard geo.contentSize.height > 0 else { return 0 }
                    // `visibleRect.maxY` already accounts for safe-area and bottom composer insets!
                    let remaining = max(0, geo.contentSize.height - geo.visibleRect.maxY)
                    if remaining <= 88 { return 0 }
                    let ratio = min(1.0, max(0.0, Double(geo.visibleRect.midY) / Double(max(1, geo.contentSize.height))))
                    return 1 + Int((ratio * 1000.0).rounded())
                } action: { _, bucket in
                    let nearBottom = (bucket == 0)
                    if nearBottom != followsBottom {
                        followsBottom = nearBottom
                    }
                    if !nearBottom, !messages.isEmpty {
                        let ratio = Double(bucket - 1) / 1000.0
                        let approxIndex = min(messages.count - 1, max(0, Int((ratio * Double(messages.count - 1)).rounded())))
                        onAnchorChange(messages[approxIndex].id)
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
