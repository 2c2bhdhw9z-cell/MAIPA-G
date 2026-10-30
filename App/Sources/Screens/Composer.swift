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
    var modelLabel: String
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

    private static let pasteAttachmentThreshold = 20_000

    @FocusState private var focused: Bool
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @State private var photoItem: PhotosPickerItem?
    @State private var choosingPhoto = false
    @State private var takingPhoto = false
    @State private var importError: String?

    private var canSend: Bool {
        (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty) && !isRunning
    }

    var body: some View {
        VStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 10) {
                TextField("Ask anything…", text: $text, axis: .vertical)
                    .font(.body)
                    .lineLimit(1...8)
                    .focused($focused)
                    .submitLabel(.return)
                    .padding(.horizontal, 4)
                    .padding(.top, 2)
                if !attachments.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 7) {
                            ForEach(attachments) { attachment in
                                HStack(spacing: 5) {
                                    Image(systemName: attachment.kind == .image ? "photo" : attachment.kind == .pdf ? "doc.richtext" : "doc")
                                    Text(attachment.name).lineLimit(1)
                                    Button { attachments.removeAll { $0.id == attachment.id } } label: { Image(systemName: "xmark") }
                                        .buttonStyle(.plain)
                                }
                                .font(.caption)
                                .padding(.horizontal, 9).padding(.vertical, 6)
                                .background(Theme.raised, in: Capsule())
                            }
                        }
                    }
                }
                HStack(alignment: .center, spacing: 6) {
                    plusMenu
                    modelButton
                    if !thinkingLevels.isEmpty { thinkingMenu }
                    Spacer(minLength: 4)
                    ContextMeter(
                        used: contextUsedTokens,
                        limit: contextLimitTokens,
                        balance: app.openRouter.balance,
                        freeRequestsLeft: app.openRouter.freeRequestsLeft
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
        .photosPicker(isPresented: $choosingPhoto, selection: $photoItem, matching: .images)
        .fullScreenCover(isPresented: $takingPhoto) {
            CameraPicker(isPresented: $takingPhoto) { data in
                Task {
                    do { attachments.append(try await AttachmentImporter.importCameraPhoto(data, store: app.attachmentStore)) }
                    catch { importError = "Couldn't add that photo." }
                }
            }
            .ignoresSafeArea()
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                do { attachments.append(try await AttachmentImporter.importPhoto(item, store: app.attachmentStore)) }
                catch { importError = "Couldn't add that photo." }
                photoItem = nil
            }
        }
        .alert("Attachment", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Button("OK") {}
        } message: { Text(importError ?? "") }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { focused = false }
                    .fontWeight(.semibold)
            }
        }
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
        Menu {
            Section {
                Button { choosingPhoto = true } label: {
                    Label("Photo library", systemImage: "photo.on.rectangle")
                }
                Button {
                    if CameraPicker.isAvailable { takingPhoto = true }
                    else { importError = "The camera isn't available." }
                } label: {
                    Label("Take a photo", systemImage: "camera")
                }
                Button { pickFile() } label: {
                    Label("Choose a file", systemImage: "doc")
                }
                Button(action: onPicture) {
                    Label("Make picture", systemImage: "paintbrush")
                }
            }

            Section {
                Button { webEnabled.toggle() } label: {
                    Label("Web search", systemImage: webEnabled ? "globe" : "globe.badge.chevron.backward")
                    Text(webEnabled ? "On" : "Off")
                }
                Button { autonomous.toggle() } label: {
                    Label("Autonomous", systemImage: autonomous ? "bolt.fill" : "bolt")
                    Text(!app.settings.autonomousEnabled ? "Enable in Settings" : (autonomous ? "On" : "Off"))
                }
                .disabled(!app.settings.autonomousEnabled)
                Button(action: onPickGroup) {
                    Label("Group", systemImage: "folder.badge.plus")
                    Text(groupName ?? "None")
                }
            }

            Section {
                Button(action: onSpec) {
                    Label("Specs", systemImage: "list.clipboard")
                }
                Button { app.sheet = .agents } label: {
                    Label("Agents", systemImage: "person.crop.circle")
                }
                Button { app.sheet = .workflows } label: {
                    Label("Workflows", systemImage: "point.3.connected.trianglepath.dotted")
                }
                Button { app.sheet = .connectors } label: {
                    Label("Connectors", systemImage: "puzzlepiece.extension")
                }
                if repo != nil {
                    if let onFiles {
                        Button(action: onFiles) {
                            Label("Repo files", systemImage: "folder")
                        }
                    }
                    Button(action: onPreview) {
                        Label("Web preview", systemImage: "safari")
                    }
                }
                if !app.jobs.jobs.isEmpty {
                    Button { app.jobs.show() } label: {
                        Label("Jobs", systemImage: "gearshape.2")
                        if app.jobs.activeCount > 0 {
                            Text("\(app.jobs.activeCount) working")
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "plus")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.primary)
                .frame(width: 32, height: 32)
                .background(Theme.raised.opacity(0.9), in: Circle())
                .overlay(Circle().strokeBorder(Theme.stroke))
                .overlay(alignment: .topTrailing) {
                    if autonomous || !webEnabled || groupName != nil {
                        Circle().fill(theme.accent).frame(width: 7, height: 7)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Tools, modes, and attachments")
    }

    private func pickFile() {
        focused = false
        AttachmentFilePicker.shared.present(
            onPick: { data, name in
                Task {
                    do { attachments.append(try await AttachmentImporter.importFile(data, name: name, store: app.attachmentStore)) }
                    catch { importError = "Couldn't add that file." }
                }
            },
            onFailure: { importError = $0 }
        )
    }

    @ViewBuilder
    private var sendButton: some View {
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
        } else {
            Button {
                guard canSend else { return }
                focused = false
                onSend()
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Color.black.opacity(canSend ? 0.85 : 0.4))
                    .frame(width: 36, height: 36)
                    .background(theme.gradient.opacity(canSend ? 1 : 0.35), in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .accessibilityLabel("Send")
        }
    }
}

/// Kiro-style context ring: how much of the selected AI's working memory this chat currently uses.
/// Tap it for the exact OpenRouter token count, model limit, and remaining OpenRouter credit.
private struct ContextMeter: View {
    var used: Int
    var limit: Int?
    var balance: Double?
    var freeRequestsLeft: Int?
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
        var parts: [String] = []
        if let balance { parts.append("Credit: \(balance.dollars)") }
        if let freeRequestsLeft { parts.append("\(freeRequestsLeft) free left today") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var body: some View {
        Button { showsDetails = true } label: {
            ZStack {
                Circle().stroke(Theme.stroke, lineWidth: 3)
                Circle()
                    .trim(from: 0, to: max(fraction, used > 0 ? 0.025 : 0))
                    .stroke(colour, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Circle().fill(colour.opacity(0.18)).padding(6)
            }
            .frame(width: 28, height: 28)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityText)
        .popover(isPresented: $showsDetails) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Context").font(.headline)
                Text(detailText).font(.subheadline.monospacedDigit())
                if let creditLine {
                    Text(creditLine)
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(Theme.secondaryText)
                }
                Text("Context is everything this AI can keep in mind for its next answer. The ring fills as this chat grows.")
                    .font(.footnote)
                    .foregroundStyle(Theme.secondaryText)
            }
            .padding(18)
            .frame(width: 290)
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
