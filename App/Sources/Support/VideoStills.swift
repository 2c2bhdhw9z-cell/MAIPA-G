import AVFoundation
import AgentCore
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Three small stills from a video the AI just made (start, middle, end), so it can see what came
/// back before it says it's done (12 November 2026: a mountain lake for a mascot, called "Made a
/// video"). Small JPEGs, so they cost little to send.
enum VideoStills {
    static func grab(_ video: Data, mimeType: String) async -> [ToolInlineImage] {
        let ext = mimeType.contains("quicktime") ? "mov" : (mimeType.contains("webm") ? "webm" : "mp4")
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("maipag-stills-\(UUID().uuidString).\(ext)")
        defer { try? FileManager.default.removeItem(at: file) }
        guard (try? video.write(to: file, options: .atomic)) != nil else { return [] }
        let asset = AVURLAsset(url: file)
        guard let duration = try? await asset.load(.duration), duration.seconds.isFinite, duration.seconds > 0 else { return [] }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 512, height: 512)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.2, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.2, preferredTimescale: 600)
        let length = duration.seconds
        let moments: [(String, Double)] = [("start", min(0.2, length / 10)), ("middle", length / 2), ("end", max(0, length - 0.2))]
        var stills: [ToolInlineImage] = []
        for (label, second) in moments {
            guard let frame = try? await generator.image(at: CMTime(seconds: second, preferredTimescale: 600)).image,
                  let jpeg = jpegData(frame) else { continue }
            stills.append(ToolInlineImage(name: "video-\(label).jpg", mimeType: "image/jpeg", data: jpeg))
        }
        return stills
    }

    private static func jpegData(_ image: CGImage) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
