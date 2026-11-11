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

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let image {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 18))
                        controls(for: image)
                    } else if isLoadingStoredImage {
                        VStack(spacing: 14) {
                            ProgressView()
                            Text("Opening picture…")
                        }
                        .frame(maxWidth: .infinity)
                        .padding(40)
                        .card()
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
                .padding()
            }
            .navigationTitle("Picture")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
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

    @ViewBuilder
    private func controls(for _: UIImage) -> some View {
        if let generated {
            if session != nil {
                HStack(spacing: 8) {
                    TextField("Describe a change…", text: $change, axis: .vertical)
                        .lineLimit(1...4)
                        .focused($changeFocused)
                        .submitLabel(.send)
                        .onSubmit { sendChange(generated) }
                    Button {
                        sendChange(generated)
                    } label: {
                        Image(systemName: "arrow.up.circle.fill").font(.title2)
                    }
                    .disabled(change.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel("Edit the picture")
                }
                .padding(12)
                .glassPanel()

                HStack {
                    Button {
                        ask("Make another version of this picture: the same idea, a fresh take.", about: generated)
                    } label: {
                        Label("Redo", systemImage: "arrow.triangle.2.circlepath")
                    }
                    Button {
                        ask("Turn this picture into a short video.", about: generated)
                    } label: {
                        Label("Video", systemImage: "play.rectangle")
                    }
                }
                .buttonStyle(.bordered)
            }
            HStack {
                Button {
                    Task { await saveToPhotos(generated) }
                } label: {
                    Label(saveState == .saving ? "Saving…" : "Save", systemImage: "square.and.arrow.down")
                }
                .disabled(saveState == .saving)
                ShareLink(item: app.paths.data.appendingPathComponent(generated.attachment.path)) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                if let target {
                    Button {
                        app.attach(generated.attachment, to: target)
                        dismiss()
                    } label: {
                        Label("Attach again", systemImage: "paperclip")
                    }
                }
            }
            .buttonStyle(.bordered)

            switch saveState {
            case .idle, .saving:
                EmptyView()
            case .saved:
                Label("Saved to Photos", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .failed(let message, let canOpenSettings):
                VStack(alignment: .leading, spacing: 8) {
                    Text(message).foregroundStyle(Theme.danger)
                    if canOpenSettings, let settings = URL(string: UIApplication.openSettingsURLString) {
                        Button("Open Settings") { openURL(settings) }
                            .buttonStyle(.bordered)
                    }
                }
            }

            Text(generated.prompt).font(.footnote).foregroundStyle(.secondary)
            HStack {
                Text(generated.model)
                if let cost = generated.cost { Text("· \(cost.dollars)") }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
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
