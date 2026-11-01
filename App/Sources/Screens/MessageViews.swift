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
                CollapsibleUserAttachmentGroup(attachments: otherAttachments)
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
                case .steered(_, let steeredMessages):
                    SteeredInlineBanner(messages: steeredMessages)
                case .activity(let id, let items, let isActive):
                    ActivityTimelineCard(id: id, items: items, isActive: isActive)
                case .subagents(let call):
                    SubagentCardsGroupView(call: call, modelName: modelName)
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
            let hasInlineSteers = turn.steps.contains { !($0.steeredMessages ?? []).isEmpty }
            ForEach(turn.notices.filter { !hasInlineSteers || !$0.hasPrefix("Steered mid-run:") }, id: \.self) { notice in
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

        func appendToolSegmentOrBuffer(_ call: ToolCallRecord, isLastStep: Bool) {
            if call.name == "launch_helpers", !SubagentRunItem.resolvedItems(for: call).isEmpty {
                flushBuffer(isActive: false)
                output.append(.subagents(call))
            } else {
                buffer.append(.tool(call))
            }
        }

        for (index, step) in turn.steps.enumerated() {
            if let steered = step.steeredMessages, !steered.isEmpty {
                flushBuffer(isActive: false)
                output.append(.steered(stepID: step.id, messages: steered))
            }
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
                    appendToolSegmentOrBuffer(call, isLastStep: isLastStep)
                }
            } else {
                for call in step.toolCalls {
                    appendToolSegmentOrBuffer(call, isLastStep: isLastStep)
                }
            }
            if index == turn.steps.count - 1 {
                let active = turn.status == .running && (!hasVisibleContent || step.toolCalls.contains(where: { $0.status == .running && $0.name != "launch_helpers" }))
                flushBuffer(isActive: active)
            }
        }
        return output
    }

    /// "Thinking…" shows until words, thoughts or a tool appear.
    private var showsThinkingLine: Bool {
        guard let last = turn.steps.last else { return true }
        if let lastSegment = segments.last {
            if case .activity(_, _, let active) = lastSegment, active { return false }
            if case .subagents(let call) = lastSegment, call.status == .running { return false }
        }
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
    case steered(stepID: UUID, messages: [String])
    case activity(id: String, items: [ActivityItem], isActive: Bool)
    case subagents(ToolCallRecord)
    case content(AssistantStep, isLive: Bool)

    var id: String {
        switch self {
        case .steered(let stepID, _): return "steered-\(stepID.uuidString)"
        case .activity(let id, _, _): return "activity-\(id)"
        case .subagents(let call): return "subagents-\(call.id)"
        case .content(let step, _): return "content-\(step.id.uuidString)"
        }
    }
}

private struct SteeredInlineBanner: View {
    let messages: [String]
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(messages.enumerated()), id: \.offset) { _, note in
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: "arrow.turn.down.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(theme.accent)
                        .padding(.top, 2)
                    Text("Steered: \(note)")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.primary.opacity(0.92))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(theme.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(theme.accent.opacity(0.30))
        )
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
                let isThoughtOnlyCard = !items.contains {
                    if case .tool = $0 { return true }
                    return false
                }
                Group {
                    if isThoughtOnlyCard {
                        let thoughtBody = VStack(alignment: .leading, spacing: 10) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
                                if case .thought(let step, _) = item {
                                    if items.count > 1 {
                                        Text(step.thinkingSeconds.map { "Step \(idx + 1) · \($0)s" } ?? "Step \(idx + 1)")
                                            .font(.caption2.weight(.semibold))
                                            .foregroundStyle(theme.accent)
                                    }
                                    Text(step.reasoning)
                                        .font(.footnote)
                                        .foregroundStyle(Theme.secondaryText)
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)

                        if timelineNeedsScroll {
                            ScrollView(.vertical, showsIndicators: true) {
                                thoughtBody
                            }
                            .frame(height: 240)
                            .background(Theme.surface.opacity(0.45), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.stroke.opacity(0.8)))
                        } else {
                            thoughtBody
                                .background(Theme.surface.opacity(0.45), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.stroke.opacity(0.8)))
                        }
                    } else if timelineNeedsScroll {
                        ScrollViewReader { timelineProxy in
                            ScrollView(.vertical, showsIndicators: true) {
                                LazyVStack(alignment: .leading, spacing: 8) {
                                    ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
                                        ActivityTimelineRow(item: item, wasRecovered: isRecoveredItem(at: idx))
                                            .id(item.id)
                                    }
                                }
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(height: 240)
                            .background(Theme.surface.opacity(0.45), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.stroke.opacity(0.8)))
                            .onChange(of: items.count) { _, _ in
                                if isActive, let lastID = items.last?.id {
                                    withAnimation(.snappy) { timelineProxy.scrollTo(lastID, anchor: .bottom) }
                                }
                            }
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
                                ActivityTimelineRow(item: item, wasRecovered: isRecoveredItem(at: idx))
                            }
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.surface.opacity(0.45), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.stroke.opacity(0.8)))
                    }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .topLeading)))
            }
        }
    }

    private var timelineNeedsScroll: Bool {
        if items.count > 6 { return true }
        return items.contains { item in
            if case .thought(let step, _) = item { return step.reasoning.count > 600 }
            return false
        }
    }

    fileprivate static func isLegacyInterruptedLaunchHelpers(_ call: ToolCallRecord) -> Bool {
        guard call.name == "launch_helpers" else { return false }
        let noChildFailed = !(call.subagents ?? []).contains(where: { $0.status == .failed })
        return noChildFailed && (call.result == nil || call.result == "Interrupted when the app closed.")
    }

    private func isRecoveredItem(at index: Int) -> Bool {
        guard items.indices.contains(index),
              case .tool(let call) = items[index],
              call.status == .failed
        else { return false }
        if Self.isLegacyInterruptedLaunchHelpers(call) { return true }
        return items.dropFirst(index + 1).contains { later in
            if case .tool(let nextCall) = later { return nextCall.status == .done }
            return false
        }
    }

    private var toolItems: [ToolCallRecord] {
        items.compactMap { if case .tool(let call) = $0 { return call }; return nil }
    }

    private var thoughtSteps: [AssistantStep] {
        items.compactMap { if case .thought(let step, _) = $0 { return step }; return nil }
    }

    private var hasFailure: Bool {
        // Only flag the collapsed header if the final tool action in this block ended in an unrecovered failure.
        guard let last = toolItems.last, last.status == .failed else { return false }
        return !Self.isLegacyInterruptedLaunchHelpers(last)
    }

    private var headerIcon: String {
        if hasFailure { return "exclamationmark.triangle" }
        if toolItems.contains(where: { $0.name == "launch_helpers" }) { return "person.2.wave.2" }
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
    var wasRecovered: Bool = false
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
                VStack(alignment: .leading, spacing: 4) {
                    Text(isLive ? "Thinking…" : (step.thinkingSeconds.map { "Thought for \($0)s" } ?? "Thoughts"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(isLive ? theme.accent : Theme.secondaryText)
                    Text(step.reasoning)
                        .font(.footnote)
                        .foregroundStyle(Theme.secondaryText)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            case .tool(let call):
                if call.name == "launch_helpers", !SubagentRunItem.resolvedItems(for: call).isEmpty {
                    SubagentCardsGroupView(call: call, modelName: { $0 })
                } else {
                    ToolLine(call: call, wasRecovered: wasRecovered)
                }
            }
        }
    }

    private var dotColor: Color {
        switch item {
        case .thought(_, let isLive):
            return isLive ? theme.accent : Theme.secondaryText.opacity(0.6)
        case .tool(let call):
            switch call.status {
            case .failed: return wasRecovered ? Theme.secondaryText.opacity(0.55) : Theme.danger
            case .running, .waitingForUser: return theme.accent
            case .done: return .green.opacity(0.75)
            }
        }
    }
}

private struct CollapsibleUserAttachmentGroup: View {
    let attachments: [AttachmentReference]
    @State private var expanded = false
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if attachments.count > 4 {
                Button {
                    withAnimation(.snappy(duration: 0.22)) { expanded.toggle() }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "paperclip")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(theme.accent)
                        Text(expanded ? "Hide \(attachments.count) files" : "\(attachments.count) attached files")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.primary)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Theme.secondaryText)
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Theme.surface, in: Capsule())
                    .overlay(Capsule().strokeBorder(Theme.stroke))
                }
                .buttonStyle(.plain)
            }
            if attachments.count <= 4 || expanded {
                HStack {
                    Spacer(minLength: 40)
                    FlowLayout(spacing: 6, lineSpacing: 6) {
                        ForEach(attachments) { attachment in
                            ChatFileAttachmentPill(attachment: attachment)
                        }
                    }
                }
            } else {
                HStack {
                    Spacer(minLength: 40)
                    FlowLayout(spacing: 6, lineSpacing: 6) {
                        ForEach(attachments.prefix(3)) { attachment in
                            ChatFileAttachmentPill(attachment: attachment)
                        }
                    }
                }
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
    private var hasFailure: Bool { calls.last?.status == .failed }

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
    var wasRecovered: Bool = false
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
                if detail.count > 600 || detail.filter({ $0 == "\n" }).count >= 10 {
                    ScrollView([.horizontal, .vertical]) {
                        Text(detail)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(Theme.secondaryText)
                            .textSelection(.enabled)
                            .fixedSize()
                            .padding(10)
                    }
                    .frame(height: 220)
                    .background(Theme.codeBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                } else {
                    ScrollView(.horizontal) {
                        Text(detail)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(Theme.secondaryText)
                            .textSelection(.enabled)
                            .fixedSize()
                            .padding(10)
                    }
                    .background(Theme.codeBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
        }
    }

    private var parsedSubagentBadge: (title: String, badge: String)? {
        guard call.name == "launch_helpers", let dotRange = call.summary.range(of: " · ") else { return nil }
        let left = String(call.summary[..<dotRange.lowerBound])
        let right = String(call.summary[dotRange.upperBound...])
        return (left, right)
    }

    private func rowLabel(showChevron: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(call.status == .failed ? (wasRecovered ? Theme.secondaryText : Theme.danger) : theme.accent)
                .frame(width: 18)
            if let sub = parsedSubagentBadge {
                Text(sub.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(call.status == .running ? .primary : Theme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .shimmer(call.status == .running && theme.thinkingShimmer)
                Text(sub.badge)
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(theme.accent)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(theme.accent.opacity(0.14), in: Capsule())
            } else {
                Text(call.summary)
                    .font(.subheadline)
                    .foregroundStyle(call.status == .running ? .primary : Theme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .shimmer(call.status == .running && theme.thinkingShimmer)
            }
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
        !(call.detail ?? call.result ?? "").isEmpty
    }

    private var icon: String {
        if call.status == .failed {
            return wasRecovered ? "arrow.triangle.2.circlepath" : "exclamationmark.triangle"
        }
        switch call.name {
        case "read_file", "read_workstation_file": return "doc.text"
        case "search_code": return "magnifyingglass"
        case "list_files", "list_workstation_files": return "folder"
        case "create_file", "edit_file", "append_file", "write_workstation_file": return "square.and.pencil"
        case "delete_file": return "trash"
        case "save_changes": return "arrow.up.doc"
        case "web_search": return "magnifyingglass"
        case "read_web_page": return "globe"
        case "read_attachment": return "paperclip"
        case "add_memory", "edit_memory": return "brain"
        case "generate_image": return "paintbrush"
        case "launch_helpers": return "person.2.wave.2"
        case "create_custom_agent": return "person.badge.plus"
        case "run_workflow", "save_workflow_definition", "inspect_workflow", "update_workflow": return "point.3.connected.trianglepath.dotted"
        case "live_status": return "waveform.path.ecg"
        case "run_shell", "run_command", "run_computer_task": return "terminal"
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

/// Kiro-style inline `ACTIVE WORKFLOWS` tree card rendered inside chat when workflows run, pause, or complete.
struct ActiveWorkflowsInlineCard: View {
    let runs: [ActiveWorkflowRunSnapshot]
    var onPause: (String) -> Void
    var onResume: (String, String?) -> Void
    var onStop: (String) -> Void
    var onRetry: (String) -> Void
    var onOpenWorkstation: () -> Void

    @State private var collapsed = false
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button {
                    withAnimation(.snappy(duration: 0.2)) { collapsed.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "point.3.connected.trianglepath.dotted")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(theme.accent)
                        Text("ACTIVE WORKFLOWS")
                            .font(.caption.weight(.bold))
                            .tracking(0.6)
                            .foregroundStyle(Theme.secondaryText)
                        Text("\(runs.count)")
                            .font(.caption2.weight(.bold).monospacedDigit())
                            .foregroundStyle(theme.accent)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(theme.accent.opacity(0.14), in: Capsule())
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Theme.secondaryText)
                            .rotationEffect(.degrees(collapsed ? 0 : 90))
                    }
                }
                .buttonStyle(.plain)

                Spacer(minLength: 8)

                Button(action: onOpenWorkstation) {
                    HStack(spacing: 4) {
                        Text("Details")
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 9, weight: .bold))
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(theme.accent)
                }
                .buttonStyle(.plain)
            }

            if !collapsed {
                ForEach(runs) { run in
                    workflowRunSection(run)
                }
            }
        }
        .padding(12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.stroke))
    }

    @ViewBuilder
    private func workflowRunSection(_ run: ActiveWorkflowRunSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                statusBadge(for: run)
                Text(run.definition.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if run.checkpoint.cumulativeCost > 0 {
                    Text(run.checkpoint.cumulativeCost.dollars)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(Theme.secondaryText)
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                ForEach(run.definition.steps) { node in
                    workflowNodeRow(node, checkpoint: run.checkpoint, depth: 0)
                }
            }

            if let latestMsg = run.checkpoint.sentMessages.last {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "bubble.left.fill")
                        .font(.caption2)
                        .foregroundStyle(theme.accent)
                    Text("\(latestMsg.title): \(latestMsg.message)")
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(2)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.raised.opacity(0.65), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            if let question = run.checkpoint.pendingQuestion {
                VStack(alignment: .leading, spacing: 6) {
                    Text(question.text)
                        .font(.caption.weight(.medium))
                    HStack(spacing: 8) {
                        ForEach(question.options, id: \.self) { opt in
                            Button(opt) {
                                onResume(run.id, opt)
                            }
                            .font(.caption.weight(.semibold))
                            .buttonStyle(.borderedProminent)
                            .buttonBorderShape(.capsule)
                        }
                    }
                }
                .padding(8)
                .background(theme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            if let err = run.errorMessage, !err.isEmpty {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(Theme.danger)
                    .lineLimit(3)
            }

            HStack(spacing: 8) {
                if run.isRunning {
                    Button { onPause(run.id) } label: {
                        Label("Pause", systemImage: "pause.fill")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)

                    Button(role: .destructive) { onStop(run.id) } label: {
                        Label("Stop", systemImage: "stop.fill")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                } else if run.checkpoint.pendingQuestion != nil || run.checkpoint.isPausedByUser {
                    Button { onResume(run.id, "Resume") } label: {
                        Label("Resume", systemImage: "play.fill")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)

                    Button(role: .destructive) { onStop(run.id) } label: {
                        Label("Stop", systemImage: "stop.fill")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                } else if run.errorMessage != nil || run.checkpoint.isCancelled {
                    Button { onRetry(run.id) } label: {
                        Label("Retry", systemImage: "arrow.clockwise")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                }
            }
        }
        .padding(10)
        .background(Theme.raised.opacity(0.45), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func workflowNodeRow(_ node: WorkflowNode, checkpoint: WorkflowCheckpoint, depth: Int) -> AnyView {
        let status = checkpoint.statuses[node.id] ?? .pending
        let iter = checkpoint.repeatIterations[node.id]
        return AnyView(
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if depth > 0 {
                        Spacer().frame(width: CGFloat(depth * 14))
                    }
                    nodeStatusIcon(status)
                    Text(node.title)
                        .font(.caption.weight(status == .running ? .semibold : .regular))
                        .foregroundStyle(status == .running ? .primary : Theme.secondaryText)
                        .lineLimit(1)
                    if node.kind != .agent {
                        Text(node.kind.rawValue)
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Theme.secondaryText)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Theme.surface, in: Capsule())
                    }
                    if let iter {
                        Text("×\(iter)")
                            .font(.caption2.weight(.bold).monospacedDigit())
                            .foregroundStyle(theme.accent)
                    }
                    if let model = node.modelID {
                        Text(AIProviderModelID.rawModelID(model).split(separator: "/").last.map(String.init) ?? model)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(Theme.secondaryText)
                            .lineLimit(1)
                    }
                }
                if !node.children.isEmpty {
                    ForEach(node.children) { child in
                        workflowNodeRow(child, checkpoint: checkpoint, depth: depth + 1)
                    }
                }
            }
        )
    }

    @ViewBuilder
    private func nodeStatusIcon(_ status: WorkflowNodeStatus) -> some View {
        switch status {
        case .pending:
            Image(systemName: "circle")
                .font(.system(size: 10))
                .foregroundStyle(Theme.secondaryText.opacity(0.5))
        case .running:
            ProgressView().controlSize(.mini)
        case .waiting:
            Image(systemName: "pause.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.orange)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(Theme.danger)
        case .cancelled:
            Image(systemName: "stop.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondaryText)
        }
    }

    @ViewBuilder
    private func statusBadge(for run: ActiveWorkflowRunSnapshot) -> some View {
        let (label, color): (String, Color) = {
            if run.isRunning { return ("Running", theme.accent) }
            if run.checkpoint.isCancelled { return ("Stopped", Theme.secondaryText) }
            if run.checkpoint.pendingQuestion != nil || run.checkpoint.isPausedByUser { return ("Paused", .orange) }
            if run.errorMessage != nil { return ("Failed", Theme.danger) }
            return ("Done", .green)
        }()
        Text(label)
            .font(.caption2.weight(.bold))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(color.opacity(0.14), in: Capsule())
    }
}

/// Kiro-style first-class Sub-Agent Cards rendered directly in chat whenever `launch_helpers` runs.
/// Every sub-agent card is individually tappable from millisecond zero — while running, after
/// finishing, or if stopped — expanding to show its exact Task, live file/tool actions, and report.
struct SubagentCardsGroupView: View {
    let call: ToolCallRecord
    var modelName: (String) -> String

    @State private var collapsedGroup = false
    @Environment(\.theme) private var theme

    private var items: [SubagentRunItem] {
        SubagentRunItem.resolvedItems(for: call)
    }

    private var duplicateNames: Set<String> {
        var counts: [String: Int] = [:]
        for item in items { counts[item.name, default: 0] += 1 }
        return Set(counts.filter { $0.value > 1 }.map(\.key))
    }

    private var isAnyRunning: Bool {
        items.contains { $0.status == .running }
    }

    private var totalActions: Int {
        items.reduce(0) { $0 + $1.toolCallCount }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if items.count > 1 {
                Button {
                    withAnimation(.snappy(duration: 0.2)) { collapsedGroup.toggle() }
                    Haptics.selection()
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "person.2.wave.2.fill")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(theme.accent)
                        Text("SUB-AGENTS")
                            .font(.caption.weight(.bold))
                            .tracking(0.6)
                            .foregroundStyle(Theme.secondaryText)
                        Text("\(items.count)")
                            .font(.caption2.weight(.bold).monospacedDigit())
                            .foregroundStyle(theme.accent)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(theme.accent.opacity(0.14), in: Capsule())
                        Text(groupStatusSummary)
                            .font(.caption)
                            .foregroundStyle(isAnyRunning ? .primary : Theme.secondaryText)
                            .lineLimit(1)
                        Spacer(minLength: 6)
                        if isAnyRunning {
                            ProgressView().controlSize(.mini)
                        }
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Theme.secondaryText)
                            .rotationEffect(.degrees(collapsedGroup ? 0 : 90))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            if !collapsedGroup || items.count == 1 {
                VStack(alignment: .leading, spacing: 8) {
                    let dupes = duplicateNames
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        SubagentItemCard(
                            item: item,
                            displayTitle: dupes.contains(item.name) ? "\(item.name) #\(index + 1)" : item.name,
                            modelName: modelName
                        )
                    }
                }
            }
        }
        .padding(items.count > 1 ? 10 : 0)
        .background(
            items.count > 1
                ? AnyShapeStyle(Theme.surface.opacity(0.45))
                : AnyShapeStyle(Color.clear),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .overlay {
            if items.count > 1 {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(isAnyRunning ? theme.accent.opacity(0.28) : Theme.stroke.opacity(0.85))
            }
        }
    }

    private var groupStatusSummary: String {
        let running = items.filter { $0.status == .running }.count
        if running > 0 {
            let actWord = totalActions == 1 ? "1 action" : "\(totalActions) actions"
            return totalActions > 0 ? "\(running) running · \(actWord)" : "\(running) running…"
        }
        let cancelled = items.filter { $0.status == .cancelled }.count
        if cancelled == items.count {
            return totalActions > 0 ? "Stopped · \(totalActions) actions" : "Stopped"
        }
        let failed = items.filter { $0.status == .failed }.count
        if failed > 0 {
            return "\(items.count - failed) done · \(failed) failed"
        }
        let actWord = totalActions == 1 ? "1 action" : "\(totalActions) actions"
        return totalActions > 0 ? "Done · \(actWord)" : "Done"
    }
}

private struct SubagentItemCard: View {
    let item: SubagentRunItem
    let displayTitle: String
    var modelName: (String) -> String

    @State private var expanded = false
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.snappy(duration: 0.22)) { expanded.toggle() }
                Haptics.selection()
            } label: {
                HStack(alignment: .center, spacing: 10) {
                    statusLeadingBadge

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Image(systemName: roleIcon)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(theme.accent)
                            Text(displayTitle)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            if let rawModel = item.model, !rawModel.isEmpty {
                                Text(modelName(rawModel))
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(Theme.secondaryText)
                                    .lineLimit(1)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Theme.raised, in: Capsule())
                            }
                        }

                        Text(subtitleText)
                            .font(.caption)
                            .foregroundStyle(item.status == .failed ? Theme.danger : Theme.secondaryText)
                            .lineLimit(expanded ? 2 : 1)
                            .truncationMode(.tail)
                            .shimmer(item.status == .running && theme.thinkingShimmer)
                    }

                    Spacer(minLength: 6)

                    rightBadge

                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Theme.secondaryText)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Sub-agent \(displayTitle)")
            .accessibilityValue(expanded ? "Expanded" : "Tap to view task, live actions, and report")

            if expanded {
                Divider()
                    .overlay(Theme.stroke.opacity(0.75))

                VStack(alignment: .leading, spacing: 10) {
                    if !item.task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("TASK")
                                .font(.caption2.weight(.bold))
                                .tracking(0.5)
                                .foregroundStyle(Theme.secondaryText)
                            if taskNeedsScroll {
                                ScrollView(.vertical, showsIndicators: true) {
                                    Text(item.task)
                                        .font(.caption)
                                        .foregroundStyle(.primary.opacity(0.9))
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(8)
                                }
                                .frame(height: 125)
                                .background(Theme.raised.opacity(0.55), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            } else {
                                Text(item.task)
                                    .font(.caption)
                                    .foregroundStyle(.primary.opacity(0.9))
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(8)
                                    .background(Theme.raised.opacity(0.55), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            }
                        }
                    }

                    if !item.toolSummaries.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("ACTIONS (\(item.toolSummaries.count))")
                                .font(.caption2.weight(.bold))
                                .tracking(0.5)
                                .foregroundStyle(Theme.secondaryText)

                            if item.toolSummaries.count > 6 {
                                ScrollView(.vertical, showsIndicators: true) {
                                    lazyActionsListView
                                        .padding(8)
                                }
                                .frame(height: 175)
                                .background(Theme.codeBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            } else {
                                actionsListView
                                    .padding(8)
                                    .background(Theme.codeBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            }
                        }
                    }

                    if item.status == .running,
                       let thought = item.liveThought?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !thought.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("THINKING LIVE")
                                .font(.caption2.weight(.bold))
                                .tracking(0.5)
                                .foregroundStyle(theme.accent)
                            Text(thought)
                                .font(.caption)
                                .foregroundStyle(Theme.secondaryText)
                                .lineLimit(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                                .background(Theme.raised.opacity(0.45), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(outputSectionTitle)
                                .font(.caption2.weight(.bold))
                                .tracking(0.5)
                                .foregroundStyle(item.status == .failed ? Theme.danger : Theme.secondaryText)
                            Spacer()
                            if !cleanedOutput.isEmpty {
                                Button {
                                    UIPasteboard.general.string = cleanedOutput
                                    Haptics.selection()
                                } label: {
                                    Label("Copy", systemImage: "doc.on.doc")
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(theme.accent)
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        if !cleanedOutput.isEmpty {
                            if outputNeedsScroll {
                                ScrollView(.vertical, showsIndicators: true) {
                                    MarkdownView(text: cleanedOutput, isStreaming: item.status == .running)
                                        .padding(10)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .frame(height: 280)
                                .background(Theme.raised.opacity(0.45), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            } else {
                                MarkdownView(text: cleanedOutput, isStreaming: item.status == .running)
                                    .padding(10)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Theme.raised.opacity(0.45), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            }
                        } else {
                            Text(emptyOutputPlaceholder)
                                .font(.caption)
                                .foregroundStyle(Theme.secondaryText)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                                .background(Theme.raised.opacity(0.35), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                    }
                }
                .padding(12)
            }
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(borderColor)
        )
    }

    private var taskNeedsScroll: Bool {
        item.task.count > 260 || item.task.filter({ $0 == "\n" }).count >= 4
    }

    private var outputNeedsScroll: Bool {
        cleanedOutput.count > 700 || cleanedOutput.filter({ $0 == "\n" }).count >= 12
    }

    private var lazyActionsListView: some View {
        LazyVStack(alignment: .leading, spacing: 5) {
            ForEach(Array(item.toolSummaries.enumerated()), id: \.offset) { idx, summary in
                actionRow(index: idx, summary: summary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var actionsListView: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(item.toolSummaries.enumerated()), id: \.offset) { idx, summary in
                actionRow(index: idx, summary: summary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func actionRow(index idx: Int, summary: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("\(idx + 1).")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(Theme.secondaryText)
                .frame(width: 24, alignment: .trailing)
            Image(systemName: actionIcon(for: summary))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(theme.accent)
                .padding(.top, 2)
            Text(summary)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.primary.opacity(0.88))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var statusLeadingBadge: some View {
        ZStack {
            Circle()
                .fill(statusColor.opacity(0.14))
                .frame(width: 26, height: 26)
            switch item.status {
            case .running:
                ProgressView().controlSize(.mini)
            case .completed:
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.green)
            case .cancelled:
                Image(systemName: "stop.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.secondaryText)
            case .failed:
                Image(systemName: "exclamationmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.danger)
            }
        }
    }

    @ViewBuilder
    private var rightBadge: some View {
        let (text, color): (String, Color) = {
            if item.toolCallCount > 0 {
                let word = item.toolCallCount == 1 ? "1 action" : "\(item.toolCallCount) actions"
                switch item.status {
                case .running: return (word, theme.accent)
                case .completed: return (word, .green)
                case .cancelled: return ("Stopped · \(item.toolCallCount)", Theme.secondaryText)
                case .failed: return ("Failed", Theme.danger)
                }
            }
            switch item.status {
            case .running: return ("Running", theme.accent)
            case .completed: return ("Done", .green)
            case .cancelled: return ("Stopped", Theme.secondaryText)
            case .failed: return ("Failed", Theme.danger)
            }
        }()
        Text(text)
            .font(.caption2.weight(.semibold).monospacedDigit())
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color.opacity(0.13), in: Capsule())
    }

    private var statusColor: Color {
        switch item.status {
        case .running: return theme.accent
        case .completed: return .green
        case .cancelled: return Theme.secondaryText
        case .failed: return Theme.danger
        }
    }

    private var borderColor: Color {
        switch item.status {
        case .running: return theme.accent.opacity(0.35)
        case .failed: return Theme.danger.opacity(0.4)
        case .completed, .cancelled: return Theme.stroke
        }
    }

    private var roleIcon: String {
        switch item.agentID {
        case "context-gatherer": return "magnifyingglass"
        case "general-task-execution": return "hammer"
        case "semantic-reviewer": return "checkmark.shield"
        case "introspect": return "waveform.path.ecg"
        case "custom-agent-creator": return "person.badge.plus"
        default: return "person.crop.circle.badge.checkmark"
        }
    }

    private func actionIcon(for summary: String) -> String {
        let lower = summary.lowercased()
        if lower.hasPrefix("read ") || lower.hasPrefix("reading ") { return "doc.text" }
        if lower.hasPrefix("search") { return "magnifyingglass" }
        if lower.hasPrefix("looked in") || lower.hasPrefix("found ") || lower.hasPrefix("list") { return "folder" }
        if lower.contains("command") || lower.contains("mcp-") { return "terminal" }
        return "sparkle"
    }

    private var subtitleText: String {
        if item.status == .running {
            if let latest = item.latestActivity, !latest.isEmpty, latest != "Starting…" {
                return latest
            }
            return firstLinePreview(of: item.task, fallback: "Starting sub-agent…")
        }
        if item.status == .failed, !cleanedOutput.isEmpty {
            return firstLinePreview(of: cleanedOutput, fallback: "Failed")
        }
        return firstLinePreview(of: item.task, fallback: item.status == .cancelled ? "Stopped" : "Completed")
    }

    private func firstLinePreview(of raw: String, fallback: String) -> String {
        let first = raw
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first(where: { !$0.isEmpty })
        guard let first, !first.isEmpty else { return fallback }
        return first.count > 120 ? String(first.prefix(120)) + "…" : first
    }

    private var cleanedOutput: String {
        let trimmed = item.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed == "cancelled" ? "" : trimmed
    }

    private var outputSectionTitle: String {
        switch item.status {
        case .running: return "LIVE OUTPUT"
        case .failed: return "ERROR"
        case .cancelled: return cleanedOutput.isEmpty ? "STATUS" : "PARTIAL REPORT"
        case .completed: return "REPORT"
        }
    }

    private var emptyOutputPlaceholder: String {
        switch item.status {
        case .running:
            if let latest = item.latestActivity, !latest.isEmpty {
                return "Currently \(latest.lowercased())"
            }
            return "Reading files and gathering context…"
        case .cancelled:
            return "Stopped before finishing its final report."
        case .failed:
            return "Sub-agent stopped with an error."
        case .completed:
            return "Completed without extra text."
        }
    }
}
