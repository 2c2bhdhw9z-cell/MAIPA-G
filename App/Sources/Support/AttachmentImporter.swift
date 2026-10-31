import AgentCore
import Foundation
import ImageIO
import PhotosUI
// PhotosPickerItem lives in the part of PhotosUI that only appears when SwiftUI is imported too.
import SwiftUI
import UIKit
import UniformTypeIdentifiers

@MainActor
enum AttachmentImporter {
    static let maximumFileBytes = AttachmentStore.maximumAttachmentBytes
    static let maximumImageDimension: CGFloat = 2_048

    enum Failure: LocalizedError {
        case tooLarge(Int)
        case unreadableImage

        var errorDescription: String? {
            switch self {
            case .tooLarge(let bytes):
                return "That file is \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)). Attach files smaller than 250 MB."
            case .unreadableImage:
                return "That picture could not be read."
            }
        }
    }

    static func importPhoto(_ item: PhotosPickerItem, baseName: String? = nil, store: AttachmentStore) async throws -> AttachmentReference {
        guard let data = try await item.loadTransferable(type: Data.self) else { throw CocoaError(.fileReadUnknown) }
        let shrunk = try shrinkImage(data)
        let prefix = baseName ?? "Photo"
        return try await store.importData(shrunk.data, name: "\(prefix).\(shrunk.extension)", mimeType: shrunk.mimeType, kind: .image)
    }

    static func importCameraPhoto(_ data: Data, store: AttachmentStore) async throws -> AttachmentReference {
        let shrunk = try shrinkImage(data)
        return try await store.importData(shrunk.data, name: "Camera Photo.\(shrunk.extension)", mimeType: shrunk.mimeType, kind: .image)
    }

    static func importFileURL(_ fileURL: URL, name: String, store: AttachmentStore) async throws -> AttachmentReference {
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let byteCount = (attrs[.size] as? Int) ?? 0
        let ext = URL(fileURLWithPath: name).pathExtension
        let type = UTType(filenameExtension: ext)
        if type?.conforms(to: .image) == true {
            // Downsample directly from the file URL via ImageIO before checking size, so even raw 60 MB
            // camera captures shrink cleanly without decoding full 48 MP bitmaps into RAM.
            let shrunk = try shrinkImageFile(at: fileURL)
            let base = URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent
            return try await store.importData(shrunk.data, name: "\(base.isEmpty ? "Image" : base).\(shrunk.extension)", mimeType: shrunk.mimeType, kind: .image)
        }
        guard byteCount <= maximumFileBytes else { throw Failure.tooLarge(byteCount) }
        let (mime, kind) = classifyNonImage(name: name, type: type)
        return try await store.importFile(at: fileURL, name: name, mimeType: mime, kind: kind, moveIfPossible: true)
    }

    static func importFile(_ data: Data, name: String, store: AttachmentStore) async throws -> AttachmentReference {
        let type = UTType(filenameExtension: URL(fileURLWithPath: name).pathExtension)
        if type?.conforms(to: .image) == true {
            let shrunk = try shrinkImage(data)
            let base = URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent
            return try await store.importData(shrunk.data, name: "\(base.isEmpty ? "Image" : base).\(shrunk.extension)", mimeType: shrunk.mimeType, kind: .image)
        }
        guard data.count <= maximumFileBytes else { throw Failure.tooLarge(data.count) }
        let (mime, kind) = classifyNonImage(name: name, type: type)
        return try await store.importData(data, name: name, mimeType: mime, kind: kind)
    }

    private static func classifyNonImage(name: String, type: UTType?) -> (mime: String, kind: AttachmentKind) {
        let lowerExt = URL(fileURLWithPath: name).pathExtension.lowercased()
        let textExtensions: Set<String> = [
            "txt", "md", "markdown", "json", "jsonl", "csv", "tsv", "yml", "yaml", "toml", "xml",
            "html", "htm", "css", "js", "mjs", "cjs", "ts", "tsx", "jsx", "swift", "py", "rb", "go",
            "rs", "java", "kt", "c", "h", "cpp", "hpp", "m", "mm", "sh", "bash", "zsh", "sql", "log",
            "env", "ini", "cfg", "conf", "diff", "patch", "svg",
        ]
        let mime = type?.preferredMIMEType ?? (textExtensions.contains(lowerExt) ? "text/plain" : "application/octet-stream")
        if type?.conforms(to: .pdf) == true || lowerExt == "pdf" { return ("application/pdf", .pdf) }
        if type?.conforms(to: .text) == true || type?.conforms(to: .sourceCode) == true || textExtensions.contains(lowerExt) {
            return (mime, .text)
        }
        return (mime, .file)
    }

    private static func shrinkImageFile(at url: URL) throws -> (data: Data, mimeType: String, extension: String) {
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions as CFDictionary) else {
            let mapped = try Data(contentsOf: url, options: .mappedIfSafe)
            return try shrinkImage(mapped)
        }
        let thumbOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maximumImageDimension),
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) else {
            let mapped = try Data(contentsOf: url, options: .mappedIfSafe)
            return try shrinkImage(mapped)
        }
        return try encodeUIImage(UIImage(cgImage: cgImage))
    }

    private static func shrinkImage(_ data: Data) throws -> (data: Data, mimeType: String, extension: String) {
        if let downsampled = ImageDownsampler.image(from: data, maxPixelSize: maximumImageDimension) {
            return try encodeUIImage(downsampled)
        }
        guard let image = UIImage(data: data) else {
            if data.count > maximumFileBytes { throw Failure.tooLarge(data.count) }
            throw Failure.unreadableImage
        }
        let scale = min(1, maximumImageDimension / max(image.size.width, image.size.height))
        let output: UIImage
        if scale < 1 {
            let size = CGSize(width: max(1, image.size.width * scale), height: max(1, image.size.height * scale))
            output = UIGraphicsImageRenderer(size: size).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        } else {
            output = image
        }
        return try encodeUIImage(output)
    }

    private static func encodeUIImage(_ output: UIImage) throws -> (data: Data, mimeType: String, extension: String) {
        let hasAlpha = output.cgImage.map {
            [.first, .last, .premultipliedFirst, .premultipliedLast].contains($0.alphaInfo)
        } ?? false
        if hasAlpha, let bytes = output.pngData(), bytes.count <= maximumFileBytes {
            return (bytes, "image/png", "png")
        }
        guard let bytes = output.jpegData(compressionQuality: 0.82) else { throw Failure.unreadableImage }
        guard bytes.count <= maximumFileBytes else { throw Failure.tooLarge(bytes.count) }
        return (bytes, "image/jpeg", "jpg")
    }
}
