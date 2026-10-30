import AgentCore
import Foundation
import PhotosUI
// PhotosPickerItem lives in the part of PhotosUI that only appears when SwiftUI is imported too.
import SwiftUI
import UIKit
import UniformTypeIdentifiers

@MainActor
enum AttachmentImporter {
    static let maximumFileBytes = 25 * 1024 * 1024
    static let maximumImageDimension: CGFloat = 2_048

    enum Failure: LocalizedError {
        case tooLarge(Int)
        case unreadableImage

        var errorDescription: String? {
            switch self {
            case .tooLarge(let bytes):
                return "That file is \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)). Attach files smaller than 25 MB."
            case .unreadableImage:
                return "That picture could not be read."
            }
        }
    }

    static func importPhoto(_ item: PhotosPickerItem, store: AttachmentStore) async throws -> AttachmentReference {
        guard let data = try await item.loadTransferable(type: Data.self) else { throw CocoaError(.fileReadUnknown) }
        let shrunk = try shrinkImage(data)
        return try await store.importData(shrunk.data, name: "Photo.\(shrunk.extension)", mimeType: shrunk.mimeType, kind: .image)
    }

    static func importCameraPhoto(_ data: Data, store: AttachmentStore) async throws -> AttachmentReference {
        let shrunk = try shrinkImage(data)
        return try await store.importData(shrunk.data, name: "Camera Photo.\(shrunk.extension)", mimeType: shrunk.mimeType, kind: .image)
    }

    static func importFile(_ data: Data, name: String, store: AttachmentStore) async throws -> AttachmentReference {
        guard data.count <= maximumFileBytes else { throw Failure.tooLarge(data.count) }
        let type = UTType(filenameExtension: URL(fileURLWithPath: name).pathExtension)
        if type?.conforms(to: .image) == true {
            let shrunk = try shrinkImage(data)
            let base = URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent
            return try await store.importData(shrunk.data, name: "\(base).\(shrunk.extension)", mimeType: shrunk.mimeType, kind: .image)
        }
        let mime = type?.preferredMIMEType ?? "application/octet-stream"
        let kind: AttachmentKind
        if type?.conforms(to: .pdf) == true { kind = .pdf }
        else if type?.conforms(to: .text) == true || type?.conforms(to: .sourceCode) == true { kind = .text }
        else { kind = .file }
        return try await store.importData(data, name: name, mimeType: mime, kind: kind)
    }

    private static func shrinkImage(_ data: Data) throws -> (data: Data, mimeType: String, extension: String) {
        guard data.count <= maximumFileBytes, let image = UIImage(data: data) else {
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
        let hasAlpha = output.cgImage.map {
            [.first, .last, .premultipliedFirst, .premultipliedLast].contains($0.alphaInfo)
        } ?? false
        if hasAlpha, let bytes = output.pngData() {
            return (bytes, "image/png", "png")
        }
        guard let bytes = output.jpegData(compressionQuality: 0.82) else { throw Failure.unreadableImage }
        return (bytes, "image/jpeg", "jpg")
    }
}
