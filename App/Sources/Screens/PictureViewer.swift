import AgentCore
import Photos
import SwiftUI
import UIKit

/// One picture from the chat, full size. Pictures are made and changed in the chat itself (owner,
/// 11 November 2026: "get rid of the make a picture tab and everything and do it when you click the
/// image in chat"), so this screen sends what you ask for back to the chat with the picture attached:
/// a change, another version, or a video. The AI picks the right model for each.
struct PictureViewer: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    let target: ComposerTarget?
    let result: GeneratedImageResult?
    @State private var generated: GeneratedImageResult?
    @State private var image: UIImage?
    @State private var isLoadingStoredImage = false
    @State private var error: String?
    @State private var saveState: PhotoSaveState = .idle
    @State private var change = ""
    @FocusState private var changeFocused: Bool

    private enum PhotoSaveState: Equatable {
        case idle, saving, saved
        case failed(message: String, canOpenSettings: Bool)
    }

    private enum PictureError: LocalizedError {
        case storedImageUnreadable

        var errorDescription: String? {
            switch self {
            case .storedImageUnreadable: return "This picture is missing or can’t be read."
            }
        }
    }

    @State private var showsPrompt = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let image {
                    // The picture fills the screen and pinches to zoom, like Photos and Grok.
                    ZoomableImageCanvas(image: image)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .padding(.horizontal, 12)
                        .padding(.top, 4)
                    if let generated { actions(for: generated) }
                } else if isLoadingStoredImage {
                    Spacer()
                    ProgressView("Opening picture…")
                    Spacer()
                } else if result != nil {
                    ContentUnavailableView {
                        Label("Picture unavailable", systemImage: "photo.badge.exclamationmark")
                    } description: {
                        Text(error ?? "This picture is missing or can’t be read.")
                    } actions: {
                        Button("Try again") { Task { await loadImage() } }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    ContentUnavailableView {
                        Label("Ask in the chat", systemImage: "sparkles")
                    } description: {
                        Text("Describe the picture or video you want in any chat, attach a photo to change it, and MAIPA-G picks the right model.")
                    }
                }
            }
            .background(Theme.background.ignoresSafeArea())
            .safeAreaInset(edge: .bottom) {
                if image != nil, let generated, session != nil { changeBar(for: generated) }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .principal) {
                    if let generated {
                        VStack(spacing: 0) {
                            Text(modelName(generated)).font(.subheadline.weight(.semibold)).lineLimit(1)
                            if let cost = generated.cost, cost > 0 { Text(cost.dollars).font(.caption2).foregroundStyle(Theme.secondaryText) }
                        }
                    }
                }
            }
            .task {
                generated = result
                if PreviewScenes.isActive, result != nil {
                    image = PreviewScenes.pictureImage()
                } else {
                    await loadImage()
                }
            }
        }
    }

    /// The chat this picture belongs to: the open one, since pictures are opened from it.
    private var session: ChatSession? { app.library.openSession }

    /// Sends a request about this picture to its chat, with the picture attached, and closes.
    private func ask(_ text: String, about picture: GeneratedImageResult) {
        guard let session else { return }
        session.send(text, attachments: [picture.attachment])
        Haptics.tap()
        dismiss()
    }

    /// The model's own name ("Gemini 3 Pro Image"), not its id; "Your computer" for one made there.
    private func modelName(_ picture: GeneratedImageResult) -> String {
        if let model = app.openRouter.modelsByID[picture.model] { return model.shortName }
        if picture.model.hasPrefix("mcp-") || picture.model == app.settings.chatComputerMachineName { return "Made on your computer" }
        let raw = AIProviderModelID.rawModelID(picture.model)
        return raw.split(separator: "/").last.map { $0.replacingOccurrences(of: "-", with: " ").capitalized } ?? "Picture"
    }

    /// Four round buttons under the picture, then the prompt behind a tap.
    @ViewBuilder
    private func actions(for picture: GeneratedImageResult) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 0) {
                if session != nil {
                    roundButton("Redo", systemImage: "arrow.triangle.2.circlepath") {
                        ask("Make another version of this picture: the same idea, a fresh take.", about: picture)
                    }
                    roundButton("Video", systemImage: "play.fill") {
                        ask("Turn this picture into a short video.", about: picture)
                    }
                }
                roundButton(saveLabel, systemImage: saveState == .saved ? "checkmark" : "arrow.down.to.line") {
                    Task { await saveToPhotos(picture) }
                }
                .disabled(saveState == .saving || saveState == .saved)
                ShareLink(item: app.paths.data.appendingPathComponent(picture.attachment.path)) {
                    roundLabel("Share", systemImage: "square.and.arrow.up")
                }
                .frame(maxWidth: .infinity)
                if let target {
                    roundButton("Attach", systemImage: "paperclip") {
                        app.attach(picture.attachment, to: target)
                        dismiss()
                    }
                }
            }
            if case .failed(let message, let canOpenSettings) = saveState {
                HStack(spacing: 8) {
                    Text(message).font(.footnote).foregroundStyle(Theme.danger)
                    if canOpenSettings, let settings = URL(string: UIApplication.openSettingsURLString) {
                        Button("Settings") { openURL(settings) }.font(.footnote.weight(.semibold))
                    }
                }
                .padding(.horizontal)
            }
            if !picture.prompt.isEmpty {
                Button {
                    withAnimation(.snappy) { showsPrompt.toggle() }
                } label: {
                    Text(picture.prompt)
                        .font(.footnote)
                        .foregroundStyle(Theme.secondaryText)
                        .multilineTextAlignment(.center)
                        .lineLimit(showsPrompt ? nil : 1)
                        .padding(.horizontal, 24)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(showsPrompt ? "Prompt, tap to fold" : "Show the prompt")
            }
        }
        .padding(.top, 14)
        .padding(.bottom, 6)
    }

    private var saveLabel: String {
        switch saveState {
        case .saving: "Saving…"
        case .saved: "Saved"
        default: "Save"
        }
    }

    private func roundButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { roundLabel(title, systemImage: systemImage) }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
    }

    private func roundLabel(_ title: String, systemImage: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 50, height: 50)
                .background(Theme.raised, in: Circle())
                .overlay(Circle().strokeBorder(Theme.stroke))
            Text(title).font(.caption).foregroundStyle(Theme.secondaryText)
        }
        .contentShape(Rectangle())
    }

    /// "Describe a change…", pinned to the bottom like the chat's own box.
    private func changeBar(for picture: GeneratedImageResult) -> some View {
        HStack(spacing: 8) {
            TextField("Describe a change…", text: $change, axis: .vertical)
                .lineLimit(1...4)
                .focused($changeFocused)
                .submitLabel(.send)
                .onSubmit { sendChange(picture) }
                .padding(.leading, 6)
            Button {
                sendChange(picture)
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(.tint))
                    .opacity(change.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.35 : 1)
            }
            .disabled(change.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityLabel("Edit the picture")
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .glassPanel(cornerRadius: 24)
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
    }

    private func sendChange(_ picture: GeneratedImageResult) {
        let text = change.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        change = ""
        changeFocused = false
        ask("Edit this picture: \(text)", about: picture)
    }

    private func loadImage() async {
        guard let generated else { return }
        isLoadingStoredImage = true
        error = nil
        defer { isLoadingStoredImage = false }
        do {
            let data = try await app.attachmentStore.data(for: generated.attachment)
            guard let decoded = ImageDownsampler.image(from: data) else { throw PictureError.storedImageUnreadable }
            image = decoded
        } catch {
            image = nil
            self.error = userMessage(for: error)
        }
    }

    private func saveToPhotos(_ generated: GeneratedImageResult) async {
        guard saveState != .saving else { return }
        saveState = .saving
        do {
            let status = await photoAuthorization()
            switch status {
            case .authorized, .limited:
                break
            case .denied:
                saveState = .failed(message: "Photos access is off. Allow MAIPA-G to add pictures in Settings, then try again.", canOpenSettings: true)
                return
            case .restricted:
                saveState = .failed(message: "This iPhone does not allow MAIPA-G to add pictures to Photos.", canOpenSettings: false)
                return
            case .notDetermined:
                saveState = .failed(message: "Photos permission was not decided. Try Save again.", canOpenSettings: false)
                return
            @unknown default:
                saveState = .failed(message: "This iPhone did not provide Photos access.", canOpenSettings: false)
                return
            }

            let data = try await app.attachmentStore.data(for: generated.attachment)
            guard ImageDownsampler.image(from: data) != nil else { throw PictureError.storedImageUnreadable }
            try await Self.addPhoto(data)
            saveState = .saved
        } catch {
            saveState = .failed(message: "Couldn’t save the picture: \(userMessage(for: error))", canOpenSettings: false)
        }
    }

    private func photoAuthorization() async -> PHAuthorizationStatus {
        await Self.requestPhotoAuthorization()
    }

    nonisolated private static func requestPhotoAuthorization() async -> PHAuthorizationStatus {
        let current = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        guard current == .notDetermined else { return current }
        return await PHPhotoLibrary.requestAuthorization(for: .addOnly)
    }

    nonisolated private static func addPhoto(_ data: Data) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
        }
    }

    private func userMessage(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
