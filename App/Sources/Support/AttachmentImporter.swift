import AgentCore
import Foundation
import PhotosUI
// PhotosPickerItem lives in the part of PhotosUI that only appears when SwiftUI is imported too.
import SwiftUI
import UniformTypeIdentifiers

@MainActor
enum AttachmentImporter {
    static func importPhoto(_ item: PhotosPickerItem, store: AttachmentStore) async throws -> AttachmentReference {
        guard let data = try await item.loadTransferable(type: Data.self) else { throw CocoaError(.fileReadUnknown) }
        let type = item.supportedContentTypes.first ?? .jpeg
        let ext = type.preferredFilenameExtension ?? "jpg"
        return try await store.importData(data, name: "Photo.\(ext)", mimeType: type.preferredMIMEType ?? "image/jpeg", kind: .image)
    }

    static func importCameraPhoto(_ data: Data, store: AttachmentStore) async throws -> AttachmentReference {
        try await store.importData(data, name: "Camera Photo.jpg", mimeType: "image/jpeg", kind: .image)
    }

    static func importFile(_ data: Data, name: String, store: AttachmentStore) async throws -> AttachmentReference {
        let type = UTType(filenameExtension: URL(fileURLWithPath: name).pathExtension)
        let mime = type?.preferredMIMEType ?? "application/octet-stream"
        let kind: AttachmentKind
        if type?.conforms(to: .image) == true { kind = .image }
        else if type?.conforms(to: .pdf) == true { kind = .pdf }
        else if type?.conforms(to: .text) == true || type?.conforms(to: .sourceCode) == true { kind = .text }
        else { kind = .file }
        return try await store.importData(data, name: name, mimeType: mime, kind: kind)
    }
}
