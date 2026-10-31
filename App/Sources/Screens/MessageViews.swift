import AgentCore
import SwiftUI
import UIKit

/// What the buttons inside a reply can do.
struct TurnActions {
    var answer: ([String]) -> Void
    var retry: () -> Void
    var retryAnswer: (UUID) -> Void
    var editMessage: (UUID, String) -> Void
    var keepGoing: () -> Void
    var approveSpending: () -> Void
    var switchToFree: () -> Void
    var signIn: () -> Void
    var openURL: (URL) -> Void
    var toggleStar: (UUID) -> Void
}

/// One message. Equatable, so while a reply streams in only the reply being written redraws.
struct MessageRow: View, Equatable {
    var message: ChatMessage
    var isLatest: Bool
    var modelName: (String) -> String
    var actions: TurnActions

    nonisolated static func == (lhs: MessageRow, rhs: MessageRow) -> Bool {
        lhs.message == rhs.message && lhs.isLatest == rhs.isLatest
    }

    var body: some View {
        switch message.body {
        case .user(let user):
            UserBubble(
                message: user,
                createdAt: message.createdAt,
                isStarred: message.starredMemoryID != nil,
                canStar: canStar,
                onToggleStar: {
                    actions.toggleStar(message.id)
                    Haptics.selection()
                },
                onEdit: { actions.editMessage(message.id, user.text) }
            )
        case .assistant(let turn):
            AssistantTurnView(
                messageID: message.id,
                createdAt: message.createdAt,
                turn: turn,
                isLatest: isLatest,
                isStarred: message.starredMemoryID != nil,
                canStar: canStar,
                modelName: modelName,
                actions: actions
            )
        }
    }

    private var canStar: Bool {
        switch message.body {
        case .user(let user): return !user.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .assistant(let turn): return turn.steps.contains { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }
    }
}

struct UserBubble: View {
    var message: UserMessage
    var createdAt: Date = Date()
    var isStarred: Bool
    var canStar: Bool
    var onToggleStar: () -> Void
    var onEdit: () -> Void
    @Environment(\.theme) private var theme
    @State private var showingFullText = false

    private static let previewCharacterLimit = 1_200
    private static let previewLineLimit = 16

    private var isLongText: Bool {
        if message.text.count > Self.previewCharacterLimit { return true }
        var lines = 1
        for character in message.text where character == "\n" {
            lines += 1
            if lines > Self.previewLineLimit { return true }
        }
        return false
    }

    private var previewText: String {
        guard isLongText else { return message.text }
        let prefix = String(message.text.prefix(Self.previewCharacterLimit))
        let lines = prefix.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.count > Self.previewLineLimit {
            return lines.prefix(Self.previewLineLimit).joined(separator: "\n") + "…"
        }
        return prefix.count < message.text.count ? prefix + "…" : prefix
    }

    private var imageAttachments: [AttachmentReference] {
        message.attachments.filter { $0.kind == .image }
    }

    private var otherAttachments: [AttachmentReference] {
        message.attachments.filter { $0.kind != .image }
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            if !imageAttachments.isEmpty {
                HStack {
                    Spacer(minLength: 40)
                    GrokPhotoStackView(images: imageAttachments)
                }
            }

            if !otherAttachments.isEmpty {
                HStack {
                    Spacer(minLength: 40)
                    FlowLayout(spacing: 6, lineSpacing: 6) {
                        ForEach(otherAttachments) { attachment in
                            ChatFileAttachmentPill(attachment: attachment)
                        }
                    }
                }
            }

            if !message.text.isEmpty {
                HStack(alignment: .center, spacing: 6) {
                    Spacer(minLength: 36)
                    if canStar {
                        Button(action: onToggleStar) {
                            Image(systemName: isStarred ? "star.fill" : "star")
                                .font(.caption)
                                .foregroundStyle(isStarred ? .yellow : Theme.secondaryText.opacity(0.75))
                                .frame(width: 28, height: 28)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(isStarred ? "Remove memory" : "Save as memory")
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text(previewText)
                            .font(.body)
                            .textSelection(.enabled)
                        if isLongText {
                            Button { showingFullText = true } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: "doc.text.magnifyingglass")
                                    Text("Show full message (\(message.text.count.formatted()) characters)")
                                    Image(systemName: "chevron.right")
                                        .font(.caption2.weight(.bold))
                                }
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(theme.accent)
                                .padding(.top, 2)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(theme.accent.opacity(0.16), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(theme.accent.opacity(0.25)))
                    .contextMenu {
                        if canStar {
                            Button(action: onToggleStar) {
                                Label(isStarred ? "Remove memory" : "Save as memory", systemImage: isStarred ? "star.slash" : "star")
                            }
                        }
                        if isLongText {
                            Button { showingFullText = true } label: { Label("Show full message", systemImage: "doc.text.magnifyingglass") }
                        }
                        if message.text.count <= 20_000 {
                            Button(action: onEdit) { Label("Edit and resend", systemImage: "pencil") }
                        }
                        Button { UIPasteboard.general.string = message.text } label: { Label("Copy", systemImage: "doc.on.doc") }
                    }
                }
            }

            Text(MessageTimestampFormatter.shortTime(createdAt))
                .font(.caption2)
                .foregroundStyle(Theme.secondaryText.opacity(0.7))
                .padding(.trailing, 4)
        }
        .sheet(isPresented: $showingFullText) {
            FullUserMessageSheet(text: message.text)
        }
    }
}

private struct FullUserMessageSheet: View {
    let text: String
    @Environment(\.dismiss) private var dismiss
    private let chunks: [String]

    init(text: String) {
        self.text = text
        self.chunks = Self.splitIntoChunks(text, targetSize: 3_000)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(chunks.enumerated()), id: \.offset) { _, chunk in
                        Text(chunk)
                            .font(.body)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(16)
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Full message")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        UIPasteboard.general.string = text
                        Haptics.selection()
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
    }

    private static func splitIntoChunks(_ text: String, targetSize: Int) -> [String] {
        guard text.count > targetSize else { return [text] }
        var result: [String] = []
        var start = text.startIndex
        while start < text.endIndex {
            let maxEnd = text.index(start, offsetBy: targetSize, limitedBy: text.endIndex) ?? text.endIndex
            if maxEnd == text.endIndex {
                result.append(String(text[start..<maxEnd]))
                break
            }
            let searchFloor = text.index(start, offsetBy: targetSize / 2, limitedBy: maxEnd) ?? start
            if let newline = text[searchFloor..<maxEnd].lastIndex(of: "\n") {
                let splitAt = text.index(after: newline)
                result.append(String(text[start..<splitAt]))
                start = splitAt
            } else {
                result.append(String(text[start..<maxEnd]))
                start = maxEnd
            }
        }
        return result
    }
}

struct AssistantTurnView: View {
    var messageID: UUID
    var createdAt: Date = Date()
    var turn: AssistantTurn
    var isLatest: Bool
    var isStarred: Bool
    var canStar: Bool
    var modelName: (String) -> String
    var actions: TurnActions
    @Environment(\.theme) private var theme
    @State private var showRelativeTime = false
    @State private var showingSources = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(segments) { segment in
                switch segment {
                case .activity(let id, let items, let isActive):
                    ActivityTimelineCard(id: id, items: items, isActive: isActive)
                case .content(let step, let isLive):
                    StepContentView(step: step, isStreaming: isLive)
                }
            }
            if turn.status == .running, showsThinkingLine {
                WorkingLine(text: "Thinking…")
            }
            if let pending = turn.pendingQuestions, isLatest {
                QuestionCard(questions: pending.questions, onSubmit: actions.answer)
            }
            if let spent = turn.spendCheck, isLatest, turn.status == .waitingForUser {
                SpendCheckCard(spent: spent, onKeepGoing: actions.approveSpending)
            }
            if let failure = turn.failure, turn.status == .failed || turn.status == .stopped {
                FailureCard(failure: failure, isLatest: isLatest, actions: actions)
            } else if turn.status == .stopped, isLatest {
                StoppedLine(onContinue: actions.keepGoing)
            }
            ForEach(turn.notices, id: \.self) { notice in
                Label(notice, systemImage: "info.circle")
                    .font(.footnote)
                    .foregroundStyle(Theme.secondaryText)
            }
            if turn.status != .running, !turn.steps.isEmpty {
                footer
                Button("Retry this answer") { actions.retryAnswer(messageID) }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(theme.accent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(isPresented: $showingSources) {
            TurnSourcesSheet(sources: collectedSources, onOpenURL: actions.openURL)
        }
    }

    private var collectedSources: [TurnSourceItem] {
        TurnSourceItem.collect(from: turn)
    }

    private var turnDurationSeconds: Int? {
        guard let firstStart = turn.steps.first?.startedAt else { return nil }
        let lastEnd = turn.steps.reversed().compactMap(\.finishedAt).first ?? createdAt
        let secs = Int(lastEnd.timeIntervalSince(firstStart).rounded())
        return secs > 0 ? secs : nil
    }

    /// Groups consecutive thoughts and tool calls into a single collapsible Arena/Kiro-style
    /// activity card that stays open while running and folds into one summary line once done.
    private var segments: [TurnSegment] {
        var output: [TurnSegment] = []
        var buffer: [ActivityItem] = []
        let lastStepID = turn.steps.last?.id

        func flushBuffer(isActive: Bool) {
            guard !buffer.isEmpty else { return }
            let id = buffer[0].id
            output.append(.activity(id: id, items: buffer, isActive: isActive))
            buffer.removeAll(keepingCapacity: true)
        }

        for (index, step) in turn.steps.enumerated() {
            let isLastStep = step.id == lastStepID
            let stepIsLive = turn.status == .running && isLastStep && step.finishedAt == nil
            let hasVisibleContent = !step.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !(step.generatedImages ?? []).isEmpty

            if !step.reasoning.isEmpty {
                buffer.append(.thought(step: step, isLive: stepIsLive && !hasVisibleContent && step.toolCalls.isEmpty && step.finishedAt == nil))
            }
            // If visible text came BEFORE toolCalls in the same step, flush thoughts before text, show text, then buffer toolCalls.
            if hasVisibleContent {
                flushBuffer(isActive: false)
                output.append(.content(step, isLive: stepIsLive))
                for call in step.toolCalls {
                    buffer.append(.tool(call))
                }
            } else {
                for call in step.toolCalls {
                    buffer.append(.tool(call))
                }
            }
            if index == turn.steps.count - 1 {
                let active = turn.status == .running && (!hasVisibleContent || step.toolCalls.contains(where: { $0.status == .running }))
                flushBuffer(isActive: active)
            }
        }
        return output
    }

    /// "Thinking…" shows until words, thoughts or a tool appear.
    private var showsThinkingLine: Bool {
        guard let last = turn.steps.last else { return true }
        if !segments.isEmpty, case .activity(_, _, let active) = segments.last, active { return false }
        if last.finishedAt != nil { return !last.toolCalls.contains { $0.status == .running } }
        return last.text.isEmpty && last.reasoning.isEmpty
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                let text = turn.steps.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n\n")
                if !text.isEmpty {
                    Button {
                        UIPasteboard.general.string = text
                        Haptics.selection()
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Copy reply")
                }
                if canStar {
                    Button {
                        actions.toggleStar(messageID)
                        Haptics.selection()
                    } label: {
                        Image(systemName: isStarred ? "star.fill" : "star")
                            .foregroundStyle(isStarred ? .yellow : Theme.secondaryText)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isStarred ? "Remove memory" : "Save as memory")
                }

                let sources = collectedSources
                if !sources.isEmpty {
                    TurnSourcesPill(sources: sources) {
                        Haptics.selection()
                        showingSources = true
                    }
                }

                Spacer(minLength: 4)

                Button {
                    showRelativeTime.toggle()
                    Haptics.selection()
                } label: {
                    Text(MessageTimestampFormatter.turnFooterTime(
                        finishedAt: turn.steps.reversed().compactMap(\.finishedAt).first ?? createdAt,
                        durationSeconds: turnDurationSeconds,
                        preferRelative: showRelativeTime
                    ))
                    .lineLimit(1)
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 6) {
                let models = turn.modelsUsed.map(modelName)
                if !models.isEmpty {
                    Text(models.joined(separator: ", "))
                }
                if let route = turn.routeLabel, route.hasPrefix("Auto") || route == "Free AIs" {
                    Text("·")
                    Text(route)
                }
                if let cost = turn.usage.cost {
                    Text("·")
                    Text(cost.dollars)
                }
            }
            .lineLimit(1)
        }
        .font(.caption)
        .foregroundStyle(Theme.secondaryText)
    }
}

enum TurnSegment: Identifiable {
    case activity(id: String, items: [ActivityItem], isActive: Bool)
    case content(AssistantStep, isLive: Bool)

    var id: String {
        switch self {
        case .activity(let id, _, _): return "activity-\(id)"
        case .content(let step, _): return "content-\(step.id.uuidString)"
        }
    }
}

enum ActivityItem: Identifiable {
    case thought(step: AssistantStep, isLive: Bool)
    case tool(ToolCallRecord)

    var id: String {
        switch self {
        case .thought(let step, _): return "thought-\(step.id.uuidString)"
        case .tool(let call): return "tool-\(call.id)"
        }
    }
}

struct StepContentView: View {
    var step: AssistantStep
    var isStreaming: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !step.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                MarkdownView(text: step.text, isStreaming: isStreaming)
            }
            ForEach(step.generatedImages ?? []) { image in
                GeneratedImageCard(result: image)
            }
        }
    }
}

/// Arena + Kiro style unified activity drawer: stays open with a live compact timeline while the
/// AI is thinking and running tools, then automatically collapses into a single summary pill once
/// that block completes. Tap anytime to open or close.
struct ActivityTimelineCard: View {
    var id: String
    var items: [ActivityItem]
    var isActive: Bool
    @State private var manualOpen: Bool?
    @Environment(\.theme) private var theme

    private var isOpen: Bool { manualOpen ?? isActive }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.snappy) {
                    manualOpen = !isOpen
                }
                Haptics.selection()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: headerIcon)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(hasFailure ? Theme.danger : theme.accent)
                        .frame(width: 18)
                    Text(headerTitle)
                        .font(.subheadline.weight(isActive ? .medium : .regular))
                        .foregroundStyle(isActive ? .primary : Theme.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .shimmer(isActive && theme.thinkingShimmer)
                    if isActive, items.count > 1 {
                        Text("\(items.count)")
                            .font(.caption2.weight(.bold).monospacedDigit())
                            .foregroundStyle(theme.accent)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(theme.accent.opacity(0.14), in: Capsule())
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Theme.secondaryText)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                    if isActive {
                        ProgressView().controlSize(.mini)
                    }
                }
                .padding(.vertical, 7)
                .padding(.horizontal, 12)
                .background(Theme.surface.opacity(isOpen ? 0.85 : 0.65), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(isActive ? theme.accent.opacity(0.32) : Theme.stroke))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(headerTitle)
            .accessibilityValue(isOpen ? "Expanded" : "Collapsed")
            .frame(maxWidth: .infinity, alignment: .leading)
            .onChange(of: isActive) { wasActive, nowActive in
                // Auto-collapse smoothly as soon as running finishes unless the user manually toggled it after finishing.
                if wasActive && !nowActive {
                    withAnimation(.snappy) {
                        manualOpen = nil
                    }
                }
            }

            if isOpen {
                ScrollViewReader { timelineProxy in
                    ScrollView(.vertical, showsIndicators: items.count > 5) {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(items) { item in
                                ActivityTimelineRow(item: item)
                                    .id(item.id)
                            }
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 240)
                    .background(Theme.surface.opacity(0.45), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.stroke.opacity(0.8)))
                    .onChange(of: items.count) { _, _ in
                        if isActive, let lastID = items.last?.id {
                            withAnimation(.snappy) { timelineProxy.scrollTo(lastID, anchor: .bottom) }
                        }
                    }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .topLeading)))
            }
        }
    }

    private var toolItems: [ToolCallRecord] {
        items.compactMap { if case .tool(let call) = $0 { return call }; return nil }
    }

    private var thoughtSteps: [AssistantStep] {
        items.compactMap { if case .thought(let step, _) = $0 { return step }; return nil }
    }

    private var hasFailure: Bool {
        toolItems.contains { $0.status == .failed }
    }

    private var headerIcon: String {
        if hasFailure { return "exclamationmark.triangle" }
        if isActive { return "sparkles" }
        if !thoughtSteps.isEmpty && !toolItems.isEmpty { return "sparkles" }
        if !toolItems.isEmpty { return "wrench.and.screwdriver" }
        return "sparkles"
    }

    private var totalSeconds: Int? {
        let starts = thoughtSteps.map(\.startedAt)
        let ends = thoughtSteps.compactMap(\.finishedAt) + toolItems.compactMap(\.finishedAt)
        if let first = starts.min(), let last = ends.max() {
            let secs = Int(round(last.timeIntervalSince(first)))
            if secs > 0 { return secs }
        }
        let summed = thoughtSteps.compactMap(\.thinkingSeconds).reduce(0, +)
        return summed > 0 ? summed : nil
    }

    private static func formatDuration(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)s" }
        let mins = seconds / 60
        let rem = seconds % 60
        return rem == 0 ? "\(mins)m" : "\(mins)m \(rem)s"
    }

    private var headerTitle: String {
        if isActive {
            if let runningTool = toolItems.last(where: { $0.status == .running }) {
                return runningTool.summary
            }
            if let waitingTool = toolItems.last(where: { $0.status == .waitingForUser }) {
                return waitingTool.summary
            }
            return "Thinking…"
        }
        let toolsCount = toolItems.count
        let durationText = totalSeconds.map(Self.formatDuration)
        if toolsCount == 0 {
            if let durationText { return "Thought for \(durationText)" }
            return thoughtSteps.count > 1 ? "Thought (\(thoughtSteps.count) steps)" : "Thoughts"
        }
        if thoughtSteps.isEmpty {
            return toolsCount == 1 ? (toolItems[0].summary) : "Ran \(toolsCount) actions"
        }
        if let durationText {
            return "Worked for \(durationText) · \(toolsCount) \(toolsCount == 1 ? "action" : "actions")"
        }
        return "Thought & ran \(toolsCount) \(toolsCount == 1 ? "action" : "actions")"
    }
}

private struct ActivityTimelineRow: View {
    var item: ActivityItem
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 2) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 7, height: 7)
                    .padding(.top, 7)
                Rectangle()
                    .fill(Theme.stroke.opacity(0.75))
                    .frame(width: 1.5)
                    .frame(maxHeight: .infinity)
            }
            .frame(width: 10)

            switch item {
            case .thought(let step, let isLive):
                ThoughtsView(step: step, isLive: isLive)
            case .tool(let call):
                ToolLine(call: call)
            }
        }
    }

    private var dotColor: Color {
        switch item {
        case .thought(_, let isLive):
            return isLive ? theme.accent : Theme.secondaryText.opacity(0.6)
        case .tool(let call):
            switch call.status {
            case .failed: return Theme.danger
            case .running, .waitingForUser: return theme.accent
            case .done: return .green.opacity(0.75)
            }
        }
    }
}

struct StepView: View {
    var step: AssistantStep
    var isLive: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !step.reasoning.isEmpty {
                ThoughtsView(step: step, isLive: isLive && step.text.isEmpty && step.finishedAt == nil)
            }
            if !step.text.isEmpty {
                MarkdownView(text: step.text)
            }
            ForEach(step.generatedImages ?? []) { image in
                GeneratedImageCard(result: image)
            }
            if !step.toolCalls.isEmpty {
                ToolCallsFold(calls: step.toolCalls)
            }
            ForEach(step.citations ?? []) { citation in
                Link(destination: URL(string: citation.url) ?? URL(string: "https://openrouter.ai")!) {
                    Label(citation.title ?? citation.url, systemImage: "link")
                        .font(.footnote).lineLimit(1)
                }
            }
        }
    }
}

struct GeneratedImageCard: View {
    @Environment(AppModel.self) private var app
    let result: GeneratedImageResult
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                Button { app.sheet = .picture(result.id) } label: {
                    card(image: image)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open generated picture")
            } else if failed {
                HStack(spacing: 8) {
                    Image(systemName: "photo.badge.exclamationmark")
                    Text("Picture unavailable")
                }
                .font(.subheadline)
                .foregroundStyle(Theme.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .card()
                .accessibilityElement(children: .combine)
            } else {
                ProgressView("Opening picture…")
                    .frame(maxWidth: .infinity)
                    .frame(height: 160)
                    .card()
            }
        }
        .task(id: result.id) {
            let key = "gen-\(result.id.uuidString)"
            if let cached = ImageDownsampler.cachedImage(key: key, maxPixelSize: 1_280) {
                image = cached
                return
            }
            do {
                let data = try await app.attachmentStore.data(for: result.attachment)
                guard let decoded = ImageDownsampler.image(from: data, maxPixelSize: 1_280, cacheKey: key) else {
                    failed = true
                    return
                }
                image = decoded
            } catch {
                failed = true
            }
        }
    }

    private func card(image: UIImage) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxHeight: 320)
                .clipShape(RoundedRectangle(cornerRadius: 16))
            HStack {
                Label("Generated picture", systemImage: "photo")
                Spacer()
                if let cost = result.cost { Text(cost.dollars) }
            }
            .font(.caption)
            .foregroundStyle(Theme.secondaryText)
        }
    }
}

/// The AI's thinking, folded away under "Thought for 12s".
struct ThoughtsView: View {
    var step: AssistantStep
    var isLive: Bool
    @State private var open = false
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.snappy) { open.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .foregroundStyle(theme.accent)
                    Text(title)
                        .shimmer(isLive && theme.thinkingShimmer)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                        .rotationEffect(.degrees(open ? 90 : 0))
                }
                .font(.subheadline)
                .foregroundStyle(Theme.secondaryText)
            }
            .buttonStyle(.plain)
            if open {
                Text(step.reasoning)
                    .font(.footnote)
                    .foregroundStyle(Theme.secondaryText)
                    .textSelection(.enabled)
                    .padding(.leading, 10)
                    .overlay(alignment: .leading) {
                        Rectangle().fill(Theme.stroke).frame(width: 2)
                    }
            }
        }
    }

    private var title: String {
        if isLive { return "Thinking…" }
        if let seconds = step.thinkingSeconds { return "Thought for \(seconds)s" }
        return "Thoughts"
    }
}

/// A whole group of tool calls. It starts folded so searches, file reads and commands don't take
/// over the conversation; the live operation still names itself in the folded heading.
struct ToolCallsFold: View {
    var calls: [ToolCallRecord]
    @State private var open = false
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.snappy) { open.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: commandCount > 0 ? "terminal" : "wrench.and.screwdriver")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(hasFailure ? Theme.danger : theme.accent)
                        .frame(width: 18)
                    Text(title)
                        .font(.subheadline)
                        .foregroundStyle(isRunning ? .primary : Theme.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .shimmer(isRunning && theme.thinkingShimmer)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Theme.secondaryText)
                        .rotationEffect(.degrees(open ? 90 : 0))
                    if isRunning { ProgressView().controlSize(.mini) }
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 10)
                .background(Theme.surface.opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityValue(open ? "Expanded" : "Collapsed")
            // The bar ends after its chevron; the free space stays outside it, so taps there do nothing.
            .frame(maxWidth: .infinity, alignment: .leading)

            if open {
                ForEach(calls) { call in ToolLine(call: call) }
                    .padding(.leading, 8)
            }
        }
    }

    private var commandCount: Int { calls.filter { $0.name == "run_shell" }.count }
    private var toolCount: Int { calls.count - commandCount }
    private var isRunning: Bool { calls.contains { $0.status == .running } }
    private var hasFailure: Bool { calls.contains { $0.status == .failed } }

    private var title: String {
        if let running = calls.last(where: { $0.status == .running }) { return running.summary }
        var parts: [String] = []
        if commandCount == 1 { parts.append("Ran command") }
        else if commandCount > 1 { parts.append("Ran \(commandCount) commands") }
        if toolCount == 1 { parts.append("1 tool call") }
        else if toolCount > 1 { parts.append("\(toolCount) tool calls") }
        return parts.joined(separator: " · ")
    }
}

/// One thing the AI did, as a short line that opens to show more.
struct ToolLine: View {
    var call: ToolCallRecord
    @State private var open = false
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if hasDetail {
                Button {
                    withAnimation(.snappy) { open.toggle() }
                } label: {
                    rowLabel(showChevron: true)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(call.summary)
                .accessibilityValue(open ? "Expanded" : "Collapsed")
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                rowLabel(showChevron: false)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(call.summary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if open, let detail = call.detail ?? call.result {
                ScrollView([.horizontal, .vertical]) {
                    Text(detail)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(Theme.secondaryText)
                        .textSelection(.enabled)
                        .fixedSize()
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 220)
                .background(Theme.codeBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }

    private func rowLabel(showChevron: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(call.status == .failed ? Theme.danger : theme.accent)
                .frame(width: 18)
            Text(call.summary)
                .font(.subheadline)
                .foregroundStyle(call.status == .running ? .primary : Theme.secondaryText)
                .lineLimit(1)
                .truncationMode(.middle)
                .shimmer(call.status == .running && theme.thinkingShimmer)
            if showChevron {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Theme.secondaryText)
                    .rotationEffect(.degrees(open ? 90 : 0))
            }
            if call.status == .running {
                ProgressView().controlSize(.mini)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(Theme.surface.opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contentShape(Rectangle())
    }

    private var hasDetail: Bool {
        !(call.detail ?? call.result ?? "").isEmpty && call.status != .running
    }

    private var icon: String {
        if call.status == .failed { return "exclamationmark.triangle" }
        switch call.name {
        case "read_file": return "doc.text"
        case "search_code": return "magnifyingglass"
        case "list_files": return "folder"
        case "create_file", "edit_file": return "square.and.pencil"
        case "delete_file": return "trash"
        case "save_changes": return "arrow.up.doc"
        case "web_search": return "magnifyingglass"
        case "read_web_page": return "globe"
        case "read_attachment": return "paperclip"
        case "add_memory", "edit_memory": return "brain"
        case "generate_image": return "paintbrush"
        case "run_shell": return "terminal"
        case let name where name.hasPrefix("mcp_"): return "puzzlepiece.extension"
        case AskUserTool.name: return "questionmark.bubble"
        default: return "wrench.and.screwdriver"
        }
    }
}

/// "Thinking…", with Spark's little cousin and a shimmer.
struct WorkingLine: View {
    var text: String
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 8) {
            Spark(size: 26, mood: .working)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(Theme.secondaryText)
                .shimmer(theme.thinkingShimmer)
        }
        .padding(.vertical, 2)
    }
}

struct StoppedLine: View {
    var onContinue: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Label("Stopped", systemImage: "stop.circle")
                .font(.footnote)
                .foregroundStyle(Theme.secondaryText)
            Button("Keep going", action: onContinue)
                .font(.footnote.weight(.semibold))
        }
    }
}

/// What went wrong, in plain words, and the buttons that fix it.
struct FailureCard: View {
    var failure: TurnFailure
    var isLatest: Bool
    var actions: TurnActions
    @State private var showDetail = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: icon).foregroundStyle(Theme.danger)
                Text(failure.message)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if isLatest {
                HStack(spacing: 10) {
                    buttons
                }
                .font(.subheadline.weight(.semibold))
            }
            if let detail = failure.detail, !detail.isEmpty {
                Button(showDetail ? "Hide details" : "Details") { showDetail.toggle() }
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
                if showDetail {
                    Text(detail)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(Theme.secondaryText)
                        .textSelection(.enabled)
                }
            }
        }
        .card()
    }

    @ViewBuilder
    private var buttons: some View {
        switch failure.kind {
        case .outOfCredits:
            Button("Switch to free AIs", action: actions.switchToFree)
                .buttonStyle(.borderedProminent)
            Button("Add credit") { actions.openURL(OpenRouterClient.creditsURL) }
                .buttonStyle(.bordered)
        case .signInNeeded:
            Button("Sign in", action: actions.signIn)
                .buttonStyle(.borderedProminent)
        case .stepLimit:
            Button("Keep going", action: actions.keepGoing)
                .buttonStyle(.borderedProminent)
        case .freeLimitReached:
            Button("Add credit") { actions.openURL(OpenRouterClient.creditsURL) }
                .buttonStyle(.bordered)
        case .tooLong:
            EmptyView()
        case .offline, .providerFailed, .other:
            Button("Try again", action: actions.retry)
                .buttonStyle(.borderedProminent)
        }
    }

    private var icon: String {
        switch failure.kind {
        case .offline: return "wifi.slash"
        case .outOfCredits, .freeLimitReached: return "creditcard"
        case .signInNeeded: return "person.crop.circle.badge.exclamationmark"
        default: return "exclamationmark.triangle"
        }
    }
}

/// "Stop and ask when a job has cost $__": the job paused here.
struct SpendCheckCard: View {
    var spent: Double
    var onKeepGoing: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(spent == 0
                  ? "This AI can use OpenRouter credit. I stopped before sending anything so you can approve it."
                  : "This job has cost \(spent.dollars) so far, so I stopped to ask.", systemImage: "dollarsign.circle")
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button("Keep going", action: onKeepGoing)
                    .buttonStyle(.borderedProminent)
                Text("or write something to stop here")
                    .font(.footnote)
                    .foregroundStyle(Theme.secondaryText)
            }
        }
        .card()
    }
}
