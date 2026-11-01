import AgentCore
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

extension ThinkingLevel {
    var label: String {
        switch self {
        case .none: return "Off"
        case .minimal: return "Minimal"
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        case .xhigh: return "Extra high"
        case .max: return "Max"
        }
    }
}

/// The message box: the text, the + tools/attachments menu, AI & thinking pickers, context meter,
/// send, and the clean repo strip underneath.
struct Composer: View {
    @Binding var text: String
    @Binding var attachments: [AttachmentReference]
    @Binding var webEnabled: Bool
    @Binding var autonomous: Bool
    var busySendMode: Binding<ChatSession.BusySendMode>? = nil
    var modelLabel: String
    var supportsTools = true
    var isImageOnlyModel = false
    var contextUsedTokens: Int
    var contextLimitTokens: Int?
    var thinking: ThinkingLevel
    var thinkingLevels: [ThinkingLevel]
    var repo: ChatRepo?
    var groupName: String?
    var isGitHubConnected: Bool
    var isRunning: Bool
    var canStop: Bool
    var onSend: () -> Void
    var onStop: () -> Void
    var onPickModel: () -> Void
    var onPickThinking: (ThinkingLevel) -> Void
    var onPickRepo: () -> Void
    var onPickBranch: () -> Void
    var onClearRepo: () -> Void
    var onPickGroup: () -> Void
    var onSpec: () -> Void
    var onPicture: () -> Void
    var onPreview: () -> Void
    var onFiles: (() -> Void)? = nil
    var onWorkstation: (() -> Void)? = nil
    var canCompact = false
    var isCompacting = false
    var canRestoreMemory = false
    var onCompact: (() -> Void)? = nil
    var onRestoreMemory: (() -> Void)? = nil

    private static let pasteAttachmentThreshold = 20_000

    @FocusState private var focused: Bool
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var choosingPhoto = false
    @State private var takingPhoto = false
    @State private var importError: String?
    @State private var attachmentsExpanded = false
    @State private var showingPlusMenu = false

    private var hasSendableContent: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty
    }

    private var effectiveBusyMode: ChatSession.BusySendMode {
        if !attachments.isEmpty { return .queue }
        return busySendMode?.wrappedValue ?? .steer
    }

    private var busyPlaceholderText: String {
        effectiveBusyMode == .steer
            ? "Steer running reply without stopping…"
            : "Queue follow-up for after this turn…"
    }

    private var canSend: Bool {
        hasSendableContent
    }

    var body: some View {
        VStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 10) {
                if !attachments.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        if attachments.count > 4 {
                            HStack(spacing: 8) {
                                Button {
                                    withAnimation(.snappy(duration: 0.22)) { attachmentsExpanded.toggle() }
                                } label: {
                                    HStack(spacing: 5) {
                                        Image(systemName: "paperclip")
                                            .font(.caption2.weight(.bold))
                                            .foregroundStyle(theme.accent)
                                        Text("\(attachments.count) attachments")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(.primary)
                                        Image(systemName: "chevron.right")
                                            .font(.system(size: 9, weight: .bold))
                                            .foregroundStyle(Theme.secondaryText)
                                            .rotationEffect(.degrees(attachmentsExpanded ? 90 : 0))
                                    }
                                }
                                .buttonStyle(.plain)
                                Spacer()
                                Button("Clear all") {
                                    withAnimation(.snappy(duration: 0.2)) {
                                        attachments.removeAll()
                                        attachmentsExpanded = false
                                    }
                                }
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(Theme.secondaryText)
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, 4)
                        }
                        if attachments.count <= 4 {
                            LazyVGrid(
                                columns: [
                                    GridItem(.flexible(minimum: 110), spacing: 7),
                                    GridItem(.flexible(minimum: 110), spacing: 7)
                                ],
                                spacing: 7
                            ) {
                                ForEach(attachments) { attachment in
                                    ArenaComposerAttachmentChip(attachment: attachment) {
                                        attachments.removeAll { $0.id == attachment.id }
                                    }
                                }
                            }
                            .padding(.vertical, 1)
                            .fixedSize(horizontal: false, vertical: true)
                        } else if attachmentsExpanded {
                            let rows = (attachments.count + 1) / 2
                            ScrollView(.vertical, showsIndicators: true) {
                                LazyVGrid(
                                    columns: [
                                        GridItem(.flexible(minimum: 110), spacing: 7),
                                        GridItem(.flexible(minimum: 110), spacing: 7)
                                    ],
                                    spacing: 7
                                ) {
                                    ForEach(attachments) { attachment in
                                        ArenaComposerAttachmentChip(attachment: attachment) {
                                            attachments.removeAll { $0.id == attachment.id }
                                        }
                                    }
                                }
                                .padding(.vertical, 1)
                            }
                            .frame(height: min(CGFloat(rows) * 44, 148))
                        } else {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 6) {
                                    ForEach(attachments.prefix(3)) { attachment in
                                        ArenaComposerAttachmentChip(attachment: attachment) {
                                            attachments.removeAll { $0.id == attachment.id }
                                        }
                                        .frame(width: 145)
                                    }
                                    Button {
                                        withAnimation(.snappy(duration: 0.22)) { attachmentsExpanded = true }
                                    } label: {
                                        Text("+\(attachments.count - 3) more")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(theme.accent)
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 8)
                                            .background(Theme.raised.opacity(0.95), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                                            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Theme.stroke))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
                TextField(
                    isRunning
                        ? busyPlaceholderText
                        : (isImageOnlyModel ? "Describe the picture to generate…" : "Ask anything…"),
                    text: $text,
                    axis: .vertical
                )
                    .font(.body)
                    .lineLimit(1...8)
                    .focused($focused)
                    .submitLabel(.return)
                    .padding(.horizontal, 4)
                    .padding(.top, 2)
                HStack(alignment: .center, spacing: 6) {
                    plusMenu
                    modelButton
                    if !thinkingLevels.isEmpty { thinkingMenu }
                    Spacer(minLength: 4)
                    if isRunning, let modeBinding = busySendMode {
                        busyModeToggle(modeBinding)
                    }
                    ContextMeter(
                        used: contextUsedTokens,
                        limit: contextLimitTokens,
                        providerBalances: app.openRouter.providerBalanceItems,
                        freeRequestsLeft: app.openRouter.freeRequestsLeft,
                        canCompact: canCompact,
                        isCompacting: isCompacting,
                        canRestoreMemory: canRestoreMemory,
                        onCompact: onCompact,
                        onRestoreMemory: onRestoreMemory
                    )
                    sendButton
                }
            }
            .padding(12)
            .glassPanel(cornerRadius: 26)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    if let repo {
                        Chip(title: repo.ref.name, systemImage: repo.isPrivate ? "lock" : "chevron.left.forwardslash.chevron.right", showsChevron: true, action: onPickRepo)
                        Chip(title: repo.branch, systemImage: "arrow.triangle.branch", showsChevron: true, action: onPickBranch)
                        Button(action: onClearRepo) {
                            Image(systemName: "xmark")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(Theme.secondaryText)
                                .frame(width: 28, height: 28)
                                .background(Theme.raised.opacity(0.9), in: Circle())
                                .overlay(Circle().strokeBorder(Theme.stroke))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("No repo")
                    } else {
                        Chip(title: isGitHubConnected ? "Add a repo" : "Connect GitHub", systemImage: isGitHubConnected ? "plus" : "link", action: onPickRepo)
                    }
                    if autonomous {
                        Chip(title: "Autonomous", systemImage: "bolt.fill", tint: theme.accent) { autonomous = false }
                    }
                    if let groupName {
                        Chip(title: groupName, systemImage: "folder.fill", showsChevron: true, tint: theme.accent, action: onPickGroup)
                    }
                    if !webEnabled {
                        Chip(title: "Web off", systemImage: "globe.badge.chevron.backward") { webEnabled = true }
                    }
                    if isImageOnlyModel {
                        Chip(title: "Image model", systemImage: "paintbrush.fill", tint: theme.accent, action: onPickModel)
                    } else if !supportsTools {
                        Chip(title: "Chat only · No tools", systemImage: "bubble.left", action: onPickModel)
                    }
                }
                .padding(.horizontal, 4)
            }
        }
        .onChange(of: text) { oldValue, newValue in
            guard newValue.count >= Self.pasteAttachmentThreshold,
                  newValue.count - oldValue.count >= 4_000
            else { return }
            let keptPrefix: String
            let pastedBody: String
            if !oldValue.isEmpty, oldValue.count < 2_000, newValue.hasPrefix(oldValue) {
                keptPrefix = oldValue
                pastedBody = String(newValue.dropFirst(oldValue.count))
            } else {
                keptPrefix = ""
                pastedBody = newValue
            }
            text = keptPrefix
            let existingCount = attachments.filter { $0.name.hasPrefix("Pasted text") }.count
            let fileName = existingCount == 0 ? "Pasted text.txt" : "Pasted text \(existingCount + 1).txt"
            let data = Data(pastedBody.utf8)
            Task {
                do {
                    let attached = try await AttachmentImporter.importFile(data, name: fileName, store: app.attachmentStore)
                    attachments.append(attached)
                } catch {
                    importError = error.localizedDescription
                }
            }
        }
        .photosPicker(
            isPresented: $choosingPhoto,
            selection: $photoItems,
            maxSelectionCount: 20,
            selectionBehavior: .ordered,
            matching: .images
        )
        .fullScreenCover(isPresented: $takingPhoto) {
            CameraPicker(isPresented: $takingPhoto) { data in
                Task {
                    do { attachments.append(try await AttachmentImporter.importCameraPhoto(data, store: app.attachmentStore)) }
                    catch { importError = "Couldn't add that photo." }
                }
            }
            .ignoresSafeArea()
        }
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            photoItems = []
            Task {
                let existingPhotos = attachments.filter { $0.kind == .image }.count
                let shouldNumber = items.count > 1 || existingPhotos > 0
                var failed = 0
                var nextNumber = existingPhotos + 1
                for item in items {
                    let baseName = shouldNumber ? "Photo \(nextNumber)" : nil
                    do {
                        attachments.append(try await AttachmentImporter.importPhoto(item, baseName: baseName, store: app.attachmentStore))
                        nextNumber += 1
                    } catch {
                        failed += 1
                    }
                }
                if failed > 0 {
                    importError = failed == 1 ? "Couldn't add 1 photo." : "Couldn't add \(failed) photos."
                }
            }
        }
        .alert("Attachment", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Button("OK") {}
        } message: { Text(importError ?? "") }
        .onChange(of: isRunning) { _, running in
            if running { focused = false }
        }
    }

    private var modelButton: some View {
        Button(action: onPickModel) {
            HStack(spacing: 4) {
                Image(systemName: modelLabel == "Auto" ? "wand.and.stars" : "cpu")
                    .foregroundStyle(theme.accent)
                Text(modelLabel)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Theme.secondaryText)
            }
            .font(.footnote.weight(.medium))
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(Theme.raised.opacity(0.9), in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.stroke))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("AI: \(modelLabel)")
    }

    private var thinkingMenu: some View {
        Menu {
            Section("Thinking") {
                ForEach(thinkingLevels.reversed(), id: \.self) { level in
                    Button {
                        focused = false
                        onPickThinking(level)
                    } label: {
                        if level == thinking { Label(level.label, systemImage: "checkmark") }
                        else { Text(level.label) }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "brain").foregroundStyle(theme.accent)
                Text(thinking.label)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Theme.secondaryText)
            }
            .fixedSize(horizontal: true, vertical: false)
            .font(.footnote.weight(.medium))
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(Theme.raised.opacity(0.9), in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.stroke))
        }
        .foregroundStyle(.primary)
        .accessibilityLabel("Thinking: \(thinking.label)")
    }

    private var plusMenu: some View {
        Button {
            focused = false
            showingPlusMenu.toggle()
            Haptics.selection()
        } label: {
            Image(systemName: "plus")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.primary)
                .frame(width: 32, height: 32)
                .background(Theme.raised.opacity(0.95), in: Circle())
                .overlay(Circle().strokeBorder(Theme.stroke))
                .overlay(alignment: .topTrailing) {
                    if autonomous || !webEnabled || groupName != nil {
                        Circle().fill(theme.accent).frame(width: 7, height: 7)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Tools, modes, and attachments")
        .popover(isPresented: $showingPlusMenu, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                plusPopoverRow("Photo library", icon: "photo.on.rectangle") {
                    showingPlusMenu = false
                    focused = false
                    choosingPhoto = true
                }
                plusPopoverRow("Take a photo", icon: "camera") {
                    showingPlusMenu = false
                    focused = false
                    if CameraPicker.isAvailable { takingPhoto = true }
                    else { importError = "The camera isn't available." }
                }
                plusPopoverRow("Choose a file", icon: "doc") {
                    showingPlusMenu = false
                    pickFile()
                }
                plusPopoverRow("Make picture", icon: "paintbrush") {
                    showingPlusMenu = false
                    onPicture()
                }

                Divider().padding(.vertical, 4)

                plusPopoverRow("Web search", icon: webEnabled ? "globe" : "globe.badge.chevron.backward", trailing: webEnabled ? "On" : "Off", highlightTrailing: webEnabled) {
                    webEnabled.toggle()
                    Haptics.selection()
                }
                plusPopoverRow(
                    "Autonomous",
                    icon: autonomous ? "bolt.fill" : "bolt",
                    trailing: !app.settings.autonomousEnabled ? "Enable in Settings" : (autonomous ? "On" : "Off"),
                    highlightTrailing: autonomous,
                    disabled: !app.settings.autonomousEnabled
                ) {
                    autonomous.toggle()
                    Haptics.selection()
                }
                plusPopoverRow("Group", icon: "folder.badge.plus", trailing: groupName ?? "None") {
                    showingPlusMenu = false
                    onPickGroup()
                }
                if let onCompact {
                    plusPopoverRow(
                        isCompacting ? "Compacting older messages…" : "Compact older messages",
                        icon: "rectangle.compress.vertical",
                        trailing: isCompacting ? "Working…" : (canCompact ? nil : "Up to date"),
                        disabled: !canCompact || isCompacting
                    ) {
                        showingPlusMenu = false
                        onCompact()
                    }
                }
                if canRestoreMemory, let onRestoreMemory {
                    plusPopoverRow("Restore full memory", icon: "arrow.uturn.backward.circle", trailing: "Undo") {
                        showingPlusMenu = false
                        onRestoreMemory()
                    }
                }

                if repo != nil || !app.jobs.jobs.isEmpty {
                    Divider().padding(.vertical, 3)
                }

                if repo != nil {
                    if let onFiles {
                        plusPopoverRow("Repo files", icon: "folder") {
                            showingPlusMenu = false
                            onFiles()
                        }
                    }
                    plusPopoverRow("Web preview", icon: "safari") {
                        showingPlusMenu = false
                        onPreview()
                    }
                }
                if !app.jobs.jobs.isEmpty {
                    plusPopoverRow("Jobs", icon: "gearshape.2", trailing: app.jobs.activeCount > 0 ? "\(app.jobs.activeCount) working" : nil) {
                        showingPlusMenu = false
                        app.jobs.show()
                    }
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .frame(width: 268)
            .background(Theme.raised.opacity(0.98))
            .presentationBackground(Theme.raised.opacity(0.98))
            .presentationCompactAdaptation(.popover)
        }
    }

    private func plusPopoverRow(
        _ title: String,
        icon: String,
        trailing: String? = nil,
        highlightTrailing: Bool = false,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(disabled ? Theme.secondaryText.opacity(0.5) : theme.accent)
                    .frame(width: 20)
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(disabled ? Theme.secondaryText.opacity(0.5) : .primary)
                    .lineLimit(1)
                Spacer(minLength: 6)
                if let trailing {
                    Text(trailing)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(highlightTrailing ? theme.accent : Theme.secondaryText)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6.5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }

    private func pickFile() {
        focused = false
        AttachmentFilePicker.shared.present(
            onPick: { files in
                Task {
                    var failures: [String] = []
                    for picked in files {
                        do {
                            attachments.append(try await AttachmentImporter.importFileURL(picked.url, name: picked.name, store: app.attachmentStore))
                        } catch let error as AttachmentImporter.Failure {
                            failures.append("\(picked.name): \(error.localizedDescription)")
                        } catch {
                            failures.append("Couldn't add \(picked.name).")
                        }
                    }
                    if !failures.isEmpty {
                        importError = failures.joined(separator: "\n")
                    }
                }
            },
            onFailure: { importError = $0 }
        )
    }

    @ViewBuilder
    private func busyModeToggle(_ modeBinding: Binding<ChatSession.BusySendMode>) -> some View {
        let activeMode = effectiveBusyMode
        Menu {
            Button {
                modeBinding.wrappedValue = .steer
                Haptics.selection()
            } label: {
                Label("Steer — guide active reply without stopping", systemImage: activeMode == .steer ? "checkmark.circle.fill" : "arrow.turn.down.right")
            }
            .disabled(!attachments.isEmpty)
            Button {
                modeBinding.wrappedValue = .queue
                Haptics.selection()
            } label: {
                Label("Queue — run after current reply finishes", systemImage: activeMode == .queue ? "checkmark.circle.fill" : "text.append")
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: activeMode == .steer ? "arrow.turn.down.right" : "text.append")
                    .font(.system(size: 10, weight: .bold))
                Text(activeMode == .steer ? "Steer" : "Queue")
                    .font(.caption.weight(.semibold))
            }
            .foregroundStyle(activeMode == .steer ? theme.accent : .primary)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(
                activeMode == .steer ? theme.accent.opacity(0.14) : Theme.raised,
                in: Capsule()
            )
            .overlay(Capsule().strokeBorder(activeMode == .steer ? theme.accent.opacity(0.35) : Theme.stroke))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Mid-turn message mode")
        .accessibilityValue(activeMode == .steer ? "Steer running reply" : "Queue follow-up")
    }

    @ViewBuilder
    private var sendButton: some View {
        HStack(spacing: 6) {
            if isRunning && canStop {
                Button(action: onStop) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.primary)
                        .frame(width: 36, height: 36)
                        .background(Theme.raised, in: Circle())
                        .overlay(Circle().strokeBorder(Theme.stroke))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Stop")
            }
            if !isRunning || hasSendableContent {
                let sendIcon: String = {
                    guard isRunning else { return "arrow.up" }
                    return effectiveBusyMode == .steer ? "arrow.turn.up.right" : "text.badge.plus"
                }()
                let sendA11yLabel: String = {
                    guard isRunning else { return "Send" }
                    return effectiveBusyMode == .steer ? "Steer running reply" : "Queue follow-up"
                }()
                Button {
                    guard canSend else { return }
                    focused = false
                    onSend()
                } label: {
                    Image(systemName: sendIcon)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Color.black.opacity(canSend ? 0.85 : 0.4))
                        .frame(width: 36, height: 36)
                        .background(theme.gradient.opacity(canSend ? 1 : 0.35), in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .accessibilityLabel(sendA11yLabel)
            }
        }
    }
}

/// Kiro-style context ring: how much of the selected AI's working memory this chat currently uses.
/// Tap it for exact token usage, full model capacity, connected provider credit, and AI compaction / restore.
private struct ContextMeter: View {
    var used: Int
    var limit: Int?
    var providerBalances: [(id: String, name: String, balance: Double)] = []
    var freeRequestsLeft: Int?
    var canCompact = false
    var isCompacting = false
    var canRestoreMemory = false
    var onCompact: (() -> Void)? = nil
    var onRestoreMemory: (() -> Void)? = nil
    @State private var showsDetails = false
    @Environment(\.theme) private var theme

    private var fraction: Double {
        guard let limit, limit > 0 else { return used > 0 ? 0.08 : 0 }
        return min(1, max(0, Double(used) / Double(limit)))
    }

    private var colour: Color {
        if fraction >= 0.9 { return Theme.danger }
        if fraction >= 0.7 { return .orange }
        return theme.accent
    }

    private var creditLine: String? {
        var parts: [String] = providerBalances.map { item in
            providerBalances.count == 1 ? "Credit: \(item.balance.dollars)" : "\(item.name): \(item.balance.dollars)"
        }
        if let freeRequestsLeft { parts.append("\(freeRequestsLeft) free left today") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var body: some View {
        Button { showsDetails = true } label: {
            ZStack {
                Circle().stroke(Theme.stroke, lineWidth: 3)
                if isCompacting {
                    ProgressView().controlSize(.mini)
                } else {
                    Circle()
                        .trim(from: 0, to: max(fraction, used > 0 ? 0.025 : 0))
                        .stroke(colour, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Circle().fill(colour.opacity(0.18)).padding(6)
                }
            }
            .frame(width: 28, height: 28)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityText)
        .popover(isPresented: $showsDetails) {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Text("Context").font(.headline)
                    Spacer()
                    if canRestoreMemory {
                        Text("Compacted")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(theme.accent)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(theme.accent.opacity(0.14), in: Capsule())
                    }
                }
                Text(detailText).font(.subheadline.monospacedDigit())
                if let creditLine {
                    Text(creditLine)
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(Theme.secondaryText)
                }
                Text("Includes system instructions, active tool schemas, and conversation history up to the selected AI's full context window.")
                    .font(.footnote)
                    .foregroundStyle(Theme.secondaryText)
                if isCompacting {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Summarizing older turns with AI…")
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(Theme.secondaryText)
                    }
                    .padding(.top, 2)
                } else {
                    if let onCompact {
                        Button {
                            showsDetails = false
                            onCompact()
                        } label: {
                            Label(canCompact ? "Compact older messages" : "Older messages already compact", systemImage: "rectangle.compress.vertical")
                                .font(.footnote.weight(.semibold))
                        }
                        .buttonStyle(.bordered)
                        .disabled(!canCompact)
                        .padding(.top, 2)
                    }
                    if canRestoreMemory, let onRestoreMemory {
                        Button {
                            showsDetails = false
                            onRestoreMemory()
                        } label: {
                            Label("Restore full memory", systemImage: "arrow.uturn.backward.circle")
                                .font(.footnote.weight(.semibold))
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
            .padding(18)
            .frame(width: 304)
            .presentationCompactAdaptation(.popover)
        }
    }

    private var detailText: String {
        if let limit, limit > 0 {
            return "\(used.formatted()) of \(limit.formatted()) tokens · \(Int((fraction * 100).rounded()))%"
        }
        return used == 0 ? "Empty — the first answer will report it." : "About \(used.formatted()) tokens used."
    }

    private var accessibilityText: String { "Context: \(detailText)" }
}

/// Arena-style compact rounded-rectangle attachment pill inside the composer box:
/// `[ 24x24 mini thumbnail / badge | filename | × ]`.
struct ArenaComposerAttachmentChip: View {
    let attachment: AttachmentReference
    var onRemove: () -> Void
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @State private var thumbnail: UIImage?

    var body: some View {
        HStack(spacing: 7) {
            ZStack {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Theme.surface)
                if let thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 24, height: 24)
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                } else {
                    Image(systemName: iconName)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(theme.accent)
                }
            }
            .frame(width: 24, height: 24)
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Theme.stroke))

            Text(attachment.name)
                .font(.caption.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.secondaryText)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(attachment.name)")
        }
        .padding(.leading, 5)
        .padding(.trailing, 6)
        .padding(.vertical, 5)
        .background(Theme.raised.opacity(0.95), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Theme.stroke))
        .task(id: attachment.id) {
            guard attachment.kind == .image || attachment.kind == .pdf else { return }
            thumbnail = await ImageDownsampler.attachmentThumbnail(attachment, store: app.attachmentStore, maxPixelSize: 96)
        }
    }

    private var iconName: String {
        switch attachment.kind {
        case .image: return "photo"
        case .pdf: return "doc.richtext"
        case .text: return "doc.text"
        case .file:
            let ext = (attachment.name as NSString).pathExtension.lowercased()
            if ["zip", "ipa", "tar", "gz"].contains(ext) { return "doc.zipper" }
            if ["p12", "cer", "mobileprovision"].contains(ext) { return "key.fill" }
            return "doc"
        }
    }
}
