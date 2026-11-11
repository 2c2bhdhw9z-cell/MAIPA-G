import AgentCore
import AVKit
import SwiftUI

/// A made picture or video in the chat: videos play in place, pictures open full size.
struct GeneratedMediaCard: View {
    let result: GeneratedImageResult

    var body: some View {
        if result.isVideo {
            GeneratedVideoCard(result: result)
        } else {
            GeneratedImageCard(result: result)
        }
    }
}

/// A video the AI made, playable right in the chat, with Share.
struct GeneratedVideoCard: View {
    @Environment(AppModel.self) private var app
    let result: GeneratedImageResult
    @State private var player: AVPlayer?
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
                if let url = try? app.attachmentStore.fileURL(for: result.attachment), player != nil {
                    ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }
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
            player = AVPlayer(url: url)
        }
    }
}
