import AgentCore
import SwiftUI
import UIKit

struct PictureViewer: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let target: ComposerTarget?
    let result: GeneratedImageResult?
    @State private var prompt = ""
    @State private var aspect: ImageAspectRatio = .square
    @State private var quality: ImageQuality = .standard
    @State private var model = ""
    @State private var generated: GeneratedImageResult?
    @State private var image: UIImage?
    @State private var isGenerating = false
    @State private var progress = ""
    @State private var error: String?
    @State private var confirmSpend = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let image {
                        Image(uiImage: image).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 18))
                        controls
                    } else if isGenerating {
                        VStack(spacing: 14) { ProgressView(); Text(progress.isEmpty ? "Generating picture…" : progress) }.frame(maxWidth: .infinity).padding(40).card()
                    } else {
                        TextField("Describe the picture…", text: $prompt, axis: .vertical).lineLimit(3...8).padding().glassPanel()
                        Picker("Shape", selection: $aspect) { ForEach(ImageAspectRatio.allCases, id: \.self) { Text(label($0)).tag($0) } }
                        Picker("Quality", selection: $quality) { Text("Standard").tag(ImageQuality.standard); Text("High").tag(ImageQuality.high) }.pickerStyle(.segmented)
                        Picker("Image AI", selection: $model) { ForEach(imageModels) { Text($0.shortName).tag($0.id) } }
                        if let error { Text(error).foregroundStyle(Theme.danger) }
                        Button("Generate picture") { confirmSpend = app.openRouter.accountState.paidAllowed(); if !confirmSpend { generate() } }.buttonStyle(.borderedProminent).disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isEmpty)
                    }
                }.padding()
            }
            .navigationTitle(image == nil ? "Make a picture" : "Picture")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .task {
                generated = result
                if model.isEmpty { model = imageModels.first?.id ?? "" }
                if PreviewScenes.scene == "picture-generating" { isGenerating = true; progress = "OpenRouter is drawing your picture…" }
                else if PreviewScenes.isActive, result != nil { image = PreviewScenes.pictureImage() }
                else { await loadImage() }
            }
            .confirmationDialog("This picture can use OpenRouter credit.", isPresented: $confirmSpend) { Button("Generate") { generate() }; Button("Cancel", role: .cancel) {} }
        }
    }

    private var imageModels: [ModelInfo] { app.openRouter.models.filter(\.generatesImages).sorted { $0.shortName < $1.shortName } }

    @ViewBuilder private var controls: some View {
        if let generated {
            HStack {
                Button { UIImageWriteToSavedPhotosAlbum(image!, nil, nil, nil) } label: { Label("Save", systemImage: "square.and.arrow.down") }
                ShareLink(item: app.paths.data.appendingPathComponent(generated.attachment.path)) { Label("Share", systemImage: "square.and.arrow.up") }
                if let target { Button { app.attach(generated.attachment, to: target); dismiss() } label: { Label("Attach again", systemImage: "paperclip") } }
            }.buttonStyle(.bordered)
            Text(generated.prompt).font(.footnote).foregroundStyle(.secondary)
            HStack { Text(generated.model); if let cost = generated.cost { Text("· \(cost.dollars)") } }.font(.caption).foregroundStyle(.secondary)
        }
    }

    private func generate() {
        guard !isGenerating else { return }; isGenerating = true; error = nil
        Task {
            do {
                let values = try await app.openRouter.client.generateImages(prompt: prompt, model: model, options: ImageGenerationOptions(aspectRatio: aspect, quality: quality)) { value in Task { @MainActor in progress = value } }
                let value = values[0]
                let attachment = try await app.attachmentStore.importGeneratedImage(value.data, name: "picture-\(value.id.uuidString.lowercased()).png", mimeType: value.mimeType)
                let saved = GeneratedImageResult(attachment: attachment, prompt: value.prompt, model: value.model, aspectRatio: aspect.rawValue, quality: quality.rawValue, cost: value.cost)
                try await app.attachmentStore.saveGeneratedMetadata(saved)
                generated = saved
                image = UIImage(data: value.data); app.sync.request(); await app.openRouter.refreshKeyInfo()
            } catch { self.error = String(describing: error) }
            isGenerating = false
        }
    }

    private func loadImage() async { if let generated, let data = try? await app.attachmentStore.data(for: generated.attachment) { image = UIImage(data: data) } }
    private func label(_ value: ImageAspectRatio) -> String { switch value { case .square: "Square"; case .portrait: "Portrait"; case .landscape: "Landscape"; case .wide: "Wide"; case .tall: "Tall" } }
}
