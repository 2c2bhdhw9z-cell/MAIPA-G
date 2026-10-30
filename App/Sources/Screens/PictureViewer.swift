import AgentCore
import Photos
import SwiftUI
import UIKit

struct PictureViewer: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    let target: ComposerTarget?
    let result: GeneratedImageResult?
    @State private var prompt = ""
    @State private var aspect: ImageAspectRatio = .square
    @State private var quality: ImageQuality = .standard
    @State private var model = ""
    @State private var generated: GeneratedImageResult?
    @State private var image: UIImage?
    @State private var isGenerating = false
    @State private var isLoadingStoredImage = false
    @State private var progress = ""
    @State private var error: String?
    @State private var confirmSpend = false
    @State private var spendApproved = false
    @State private var saveState: PhotoSaveState = .idle

    private enum PhotoSaveState: Equatable {
        case idle, saving, saved
        case failed(message: String, canOpenSettings: Bool)
    }

    private enum PictureError: LocalizedError {
        case noReadableImage
        case storedImageUnreadable

        var errorDescription: String? {
            switch self {
            case .noReadableImage: return "No readable picture came back. Try again."
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
                    } else if isGenerating || isLoadingStoredImage {
                        VStack(spacing: 14) {
                            ProgressView()
                            Text(isLoadingStoredImage ? "Opening picture…" : (progress.isEmpty ? "Generating picture…" : progress))
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
                        generator
                    }
                }
                .padding()
            }
            .navigationTitle(result != nil || generated != nil ? "Picture" : "Make a picture")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .task {
                generated = result
                if model.isEmpty { model = imageModels.first?.id ?? "" }
                if PreviewScenes.scene == "picture-generating" {
                    isGenerating = true
                    progress = "OpenRouter is drawing your picture…"
                } else if PreviewScenes.isActive, result != nil {
                    image = PreviewScenes.pictureImage()
                } else {
                    await loadImage()
                }
            }
            .confirmationDialog(spendMessage, isPresented: $confirmSpend) {
                Button("Generate") { spendApproved = true; generate() }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    private var generator: some View {
        VStack(alignment: .leading, spacing: 16) {
            TextField("Describe the picture…", text: $prompt, axis: .vertical)
                .lineLimit(3...8)
                .padding()
                .glassPanel()
            Picker("Shape", selection: $aspect) {
                ForEach(ImageAspectRatio.allCases, id: \.self) { Text(label($0)).tag($0) }
            }
            Picker("Quality", selection: $quality) {
                Text("Standard").tag(ImageQuality.standard)
                Text("High").tag(ImageQuality.high)
            }
            .pickerStyle(.segmented)
            Picker("Image AI", selection: $model) {
                ForEach(imageModels) { Text($0.shortName).tag($0.id) }
            }
            if let error { Text(error).foregroundStyle(Theme.danger) }
            Button(error == nil ? "Generate picture" : "Retry") {
                let paid = imageModels.first(where: { $0.id == model })?.isFree == false
                confirmSpend = paid
                if !paid { generate() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isEmpty)
        }
    }

    private var imageModels: [ModelInfo] {
        app.openRouter.models.filter(\.generatesImages).sorted { $0.shortName < $1.shortName }
    }

    @ViewBuilder
    private func controls(for _: UIImage) -> some View {
        if let generated {
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

    private var spendMessage: String {
        if app.settings.spendLimitOn {
            return "This billed picture is a separate paid operation. Your stop-and-ask amount is \(app.settings.spendLimit.dollars); approve it before OpenRouter starts."
        }
        return "This picture can use OpenRouter credit."
    }

    private func generate() {
        let paid = imageModels.first(where: { $0.id == model })?.isFree == false
        guard !paid || spendApproved else { confirmSpend = true; return }
        spendApproved = false
        guard !isGenerating else { return }
        isGenerating = true
        error = nil
        progress = ""
        saveState = .idle
        Task {
            defer { isGenerating = false }
            do {
                let values = try await app.openRouter.client.generateImages(
                    prompt: prompt,
                    model: model,
                    options: ImageGenerationOptions(aspectRatio: aspect, quality: quality)
                ) { value in
                    Task { @MainActor in progress = value }
                }
                guard let value = values.first(where: { UIImage(data: $0.data) != nil }),
                      let decoded = UIImage(data: value.data)
                else { throw PictureError.noReadableImage }

                // Validate bytes before saving either the attachment or its metadata.
                let attachment = try await app.attachmentStore.importGeneratedImage(
                    value.data,
                    name: "picture-\(value.id.uuidString.lowercased()).png",
                    mimeType: value.mimeType
                )
                let saved = GeneratedImageResult(
                    attachment: attachment,
                    prompt: value.prompt,
                    model: value.model,
                    aspectRatio: aspect.rawValue,
                    quality: quality.rawValue,
                    cost: value.cost
                )
                try await app.attachmentStore.saveGeneratedMetadata(saved)
                generated = saved
                image = decoded
                app.sync.request()
                await app.openRouter.refreshKeyInfo()
            } catch {
                self.error = userMessage(for: error)
            }
        }
    }

    private func loadImage() async {
        guard let generated else { return }
        isLoadingStoredImage = true
        error = nil
        defer { isLoadingStoredImage = false }
        do {
            let data = try await app.attachmentStore.data(for: generated.attachment)
            guard let decoded = UIImage(data: data) else { throw PictureError.storedImageUnreadable }
            image = decoded
        } catch {
            image = nil
            error = userMessage(for: error)
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
            guard UIImage(data: data) != nil else { throw PictureError.storedImageUnreadable }
            try await addPhoto(data)
            saveState = .saved
        } catch {
            saveState = .failed(message: "Couldn’t save the picture: \(userMessage(for: error))", canOpenSettings: false)
        }
    }

    private func photoAuthorization() async -> PHAuthorizationStatus {
        let current = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        guard current == .notDetermined else { return current }
        return await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { continuation.resume(returning: $0) }
        }
    }

    private func addPhoto(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
            } completionHandler: { success, error in
                if let error { continuation.resume(throwing: error) }
                else if success { continuation.resume() }
                else { continuation.resume(throwing: PictureError.storedImageUnreadable) }
            }
        }
    }

    private func userMessage(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    private func label(_ value: ImageAspectRatio) -> String {
        switch value {
        case .square: "Square"
        case .portrait: "Portrait"
        case .landscape: "Landscape"
        case .wide: "Wide"
        case .tall: "Tall"
        }
    }
}
