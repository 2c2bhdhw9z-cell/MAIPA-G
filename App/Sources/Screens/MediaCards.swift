import AgentCore
import AVKit
import SwiftUI

/// A made picture or video in the chat: videos play in place, pictures open full size.
struct GeneratedMediaCard: View {
    let result: GeneratedImageResult

    var body: some View {
        if result.isVideo {
            GeneratedVideoCard(result: result)
        } else if result.isFile {
            GeneratedFileCard(result: result)
        } else {
            GeneratedImageCard(result: result)
        }
    }
}

/// A file the AI handed over (a built .ipa, a .deb, a zip): tap Share to open it in a sideloading
/// app or save it to Files.
struct GeneratedFileCard: View {
    @Environment(AppModel.self) private var app
    let result: GeneratedImageResult

    private var ext: String { (result.attachment.name as NSString).pathExtension.uppercased() }
    private var icon: String {
        switch ext {
        case "IPA": "app.badge"
        case "ZIP": "doc.zipper"
        case "DEB", "DYLIB": "shippingbox"
        case "PDF": "doc.richtext"
        default: "doc"
        }
    }

    var body: some View {
        let location = GeneratedMediaLocations.location(for: result.attachment, store: app.attachmentStore)
        let url = location.url
        let exists = location.exists
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 44, height: 44)
                .background(Theme.sunken, in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 2) {
                Text(result.attachment.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(exists ? "\(ext.isEmpty ? "File" : ext) · \(ByteCountFormatter.string(fromByteCount: Int64(result.attachment.bytes), countStyle: .file))" : "Still coming from your computer…")
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
            }
            Spacer(minLength: 8)
            if let url, exists {
                ShareLink(item: url) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.body.weight(.semibold))
                        .frame(width: 40, height: 40)
                        .background(Theme.raised, in: Circle())
                        .overlay(Circle().strokeBorder(Theme.stroke))
                }
                .accessibilityLabel("Open or save \(result.attachment.name)")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
        .accessibilityElement(children: .combine)
    }
}

/// A video the AI made, playable right in the chat, with Share.
struct GeneratedVideoCard: View {
    @Environment(AppModel.self) private var app
    let result: GeneratedImageResult
    @State private var player: AVPlayer?
    /// The video's file, worked out once when it opens rather than on every redraw.
    @State private var shareURL: URL?
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let player {
                VideoPlayer(player: player)
                    .frame(height: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
            } else if failed {
                HStack(spacing: 8) {
                    Image(systemName: "video.badge.exclamationmark")
                    Text("Video unavailable")
                }
                .font(.subheadline)
                .foregroundStyle(Theme.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .card()
            } else {
                ProgressView("Opening video…")
                    .frame(maxWidth: .infinity)
                    .frame(height: 160)
                    .card()
            }
            HStack {
                Label("Made video", systemImage: "play.rectangle")
                Spacer()
                if let cost = result.cost { Text(cost.dollars) }
                if let shareURL, player != nil {
                    ShareLink(item: shareURL) { Image(systemName: "square.and.arrow.up") }
                        .accessibilityLabel("Share the video")
                }
            }
            .font(.caption)
            .foregroundStyle(Theme.secondaryText)
        }
        .task(id: result.id) {
            guard let url = try? app.attachmentStore.fileURL(for: result.attachment),
                  FileManager.default.fileExists(atPath: url.path) else {
                failed = true
                return
            }
            shareURL = url
            player = AVPlayer(url: url)
        }
    }
}

/// Where a made file is on the phone. Once a file is there it stays, so after the first look the
/// answer comes from memory instead of the disk on every redraw.
@MainActor
enum GeneratedMediaLocations {
    private static var present: [UUID: URL] = [:]

    static func location(for attachment: AttachmentReference, store: AttachmentStore) -> (url: URL?, exists: Bool) {
        if let known = present[attachment.id] { return (known, true) }
        guard let url = try? store.fileURL(for: attachment) else { return (nil, false) }
        let exists = FileManager.default.fileExists(atPath: url.path)
        if exists { present[attachment.id] = url }
        return (url, exists)
    }
}


/// A picture model's own name for showing ("Gemini 3 Pro Image"), never its id.
@MainActor
enum MediaNames {
    static func model(_ id: String, app: AppModel) -> String {
        if let model = app.openRouter.modelsByID[id] { return model.shortName }
        if id == "file" { return "File" }
        if id.hasPrefix("mcp-") || id == app.settings.chatComputerMachineName { return "Made on your computer" }
        let raw = AIProviderModelID.rawModelID(id)
        if let match = app.openRouter.allSelectableModels.first(where: { AIProviderModelID.rawModelID($0.id) == raw }) { return match.shortName }
        let last = raw.split(separator: "/").last.map(String.init) ?? raw
        return last.split(separator: "-").map { word in
            let text = String(word)
            return text.count <= 3 && text.contains(where: \.isNumber) ? text : text.prefix(1).uppercased() + text.dropFirst()
        }.joined(separator: " ")
    }
}
