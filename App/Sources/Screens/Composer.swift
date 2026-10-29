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

/// The message box: the text, the AI picker, thinking, send, and (on the home screen and in
/// chats) the repo and branch pickers under it.
struct Composer: View {
    @Binding var text: String
    @Binding var attachments: [AttachmentReference]
    @Binding var webEnabled: Bool
    var modelLabel: String
    var thinking: ThinkingLevel
    var thinkingLevels: [ThinkingLevel]
    var repo: ChatRepo?
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

    @FocusState private var focused: Bool
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @State private var photoItem: PhotosPickerItem?
    @State private var choosingFile = false
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
                HStack(spacing: 8) {
                    Chip(title: modelLabel, systemImage: modelLabel == "Auto" ? "wand.and.stars" : "cpu", showsChevron: true, tint: theme.accent, action: onPickModel)
                    if !thinkingLevels.isEmpty {
                        Menu {
                            Section("Thinking") {
                                ForEach(thinkingLevels.reversed(), id: \.self) { level in
                                    Button {
                                        onPickThinking(level)
                                    } label: {
                                        if level == thinking {
                                            Label(level.label, systemImage: "checkmark")
                                        } else {
                                            Text(level.label)
                                        }
                                    }
                                }
                            }
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "brain")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(theme.accent)
                                Text(thinking.label)
                                    .font(.footnote.weight(.medium))
                                Image(systemName: "chevron.down")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(Theme.secondaryText)
                            }
                            .padding(.horizontal, 11)
                            .padding(.vertical, 7)
                            .background(Theme.raised.opacity(0.9), in: Capsule())
                            .overlay(Capsule().strokeBorder(Theme.stroke))
                        }
                        .foregroundStyle(.primary)
                        .accessibilityLabel("Thinking: \(thinking.label)")
                    }
                    Spacer(minLength: 0)
                    sendButton
                }
            }
            .padding(12)
            .glassPanel(cornerRadius: 26)

            HStack(spacing: 8) {
                Button { webEnabled.toggle() } label: {
                    Label("Web", systemImage: webEnabled ? "globe" : "globe.badge.chevron.backward")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(webEnabled ? theme.accent.opacity(0.16) : Theme.raised, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(webEnabled ? "Web tools on" : "Web tools off")
                PhotosPicker(selection: $photoItem, matching: .images) {
                    Label("Photo", systemImage: "photo").font(.caption.weight(.semibold))
                }
                Button { choosingFile = true } label: { Label("File", systemImage: "paperclip").font(.caption.weight(.semibold)) }
                Spacer()
            }
            .padding(.horizontal, 4)

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
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4)
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                do { attachments.append(try await AttachmentImporter.importPhoto(item, store: app.attachmentStore)) }
                catch { importError = "Couldn't add that photo." }
                photoItem = nil
            }
        }
        .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.item]) { result in
            guard case .success(let url) = result else { return }
            Task {
                do { attachments.append(try await AttachmentImporter.importFile(url, store: app.attachmentStore)) }
                catch { importError = "Couldn't add that file." }
            }
        }
        .alert("Attachment", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Button("OK") {}
        } message: { Text(importError ?? "") }
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
