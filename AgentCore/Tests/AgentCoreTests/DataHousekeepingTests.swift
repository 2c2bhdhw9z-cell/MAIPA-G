import Foundation
import Testing
@testable import AgentCore

@Suite("Saved data housekeeping")
struct DataHousekeepingTests {
    @Test func keepsReferencedBlobsAndRemovesOldOrphans() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("maipag-housekeeping-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ChatStore(dataDirectory: root)
        let attachments = AttachmentStore(dataDirectory: root)
        let kept = try await attachments.importData(Data("kept".utf8), name: "kept.txt", mimeType: "text/plain", kind: .text)
        let orphan = try await attachments.importData(Data("orphan".utf8), name: "orphan.txt", mimeType: "text/plain", kind: .text)
        var chat = Chat(title: "References attachment")
        chat.messages = [.user("keep", attachments: [kept])]
        try await store.save(chat)
        let old = Date(timeIntervalSince1970: 1_000)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: root.appendingPathComponent(kept.path).path)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: root.appendingPathComponent(orphan.path).path)

        let report = await DataHousekeeping(dataDirectory: root).run(now: old.addingTimeInterval(8 * 24 * 60 * 60))
        #expect(report.removedOrphanBlobs == 1)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(kept.path).path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(orphan.path).path))
    }

    @Test func imageEditKeepsSourceAndMaskThroughHousekeeping() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("maipag-image-edit-retention-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AttachmentStore(dataDirectory: root)
        let source = try await store.importGeneratedImage(Data("source".utf8), name: "source.png", mimeType: "image/png")
        let sourceResult = GeneratedImageResult(attachment: source, prompt: "source", model: "fake", aspectRatio: "1:1", quality: "standard")
        try await store.saveGeneratedMetadata(sourceResult)
        let geometry = ImageEditMask(sourcePixelWidth: 10, sourcePixelHeight: 10, strokes: [
            ImageBrushStroke(points: [ImageBrushPoint(x: 0.2, y: 0.3)], radius: 0.05)
        ])
        let response = ImageEditResponse(
            imageData: Data([0xff, 0xd8, 0xff, 0xd9]), mimeType: "image/jpeg", provider: "Fixture", model: "fake-edit",
            modelVersion: "local-fixture-v1", seed: 42, cost: 0.05
        )
        let editedResult = try await store.saveEditedImage(
            response, from: sourceResult, instruction: "replace the painted area", maskData: Data("mask".utf8), maskGeometry: geometry
        )
        let mask = try #require(editedResult.maskAttachment)
        #expect(editedResult.parentImageID == source.id)
        #expect(editedResult.editInstruction == "replace the painted area")
        #expect(editedResult.seed == 42)
        #expect(try await store.data(for: source) == Data("source".utf8))

        var step = AssistantStep()
        step.generatedImages = [editedResult]
        var chat = Chat(title: "Brush edit")
        chat.messages = [ChatMessage(body: .assistant(AssistantTurn(status: .done, steps: [step])))]
        let chatStore = ChatStore(dataDirectory: root)
        try await chatStore.save(chat)
        let reopened = try #require(await chatStore.load(chat.id))
        let reopenedEdit = try #require(reopened.messages.first?.assistantTurn?.steps.first?.generatedImages?.first)
        #expect(reopenedEdit.parentImageID == source.id)
        #expect(reopenedEdit.maskAttachment?.id == mask.id)
        #expect(reopenedEdit.maskGeometry?.sourcePixelWidth == 10)

        let old = Date(timeIntervalSince1970: 1_000)
        for path in [source.path, mask.path, editedResult.attachment.path,
                     "media/\(source.id.uuidString.lowercased()).json",
                     "media/\(editedResult.id.uuidString.lowercased()).json"] {
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: root.appendingPathComponent(path).path)
        }
        _ = await DataHousekeeping(dataDirectory: root).run(now: old.addingTimeInterval(8 * 24 * 60 * 60))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(source.path).path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(mask.path).path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(editedResult.attachment.path).path))
        let persisted = try await store.generatedMetadata(editedResult.id)
        #expect(persisted.parentImageID == source.id)
        #expect(persisted.maskAttachment?.id == mask.id)
        #expect(persisted.maskGeometry?.strokes.first?.points.first?.x == 0.2)
        #expect(persisted.seed == 42)
    }

    @Test func oldGeneratedImageRecordDecodesWithoutEditFields() throws {
        let attachment = AttachmentReference(id: UUID(), name: "old.png", mimeType: "image/png", kind: .image, path: "media/old.png", bytes: 4)
        let oldRecord = GeneratedImageResult(attachment: attachment, prompt: "old", model: "model", aspectRatio: "1:1", quality: "standard")
        let encoded = try JSONCoding.encoder().encode(oldRecord)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        for key in ["provider", "modelVersion", "seed", "parentImageID", "editInstruction", "maskAttachment", "maskGeometry"] {
            object.removeValue(forKey: key)
        }
        let legacy = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONCoding.decoder().decode(GeneratedImageResult.self, from: legacy)
        #expect(decoded.attachment.id == attachment.id)
        #expect(decoded.attachment.name == attachment.name)
        #expect(decoded.attachment.mimeType == attachment.mimeType)
        #expect(decoded.attachment.kind == attachment.kind)
        #expect(decoded.attachment.path == attachment.path)
        #expect(decoded.attachment.bytes == attachment.bytes)
        #expect(decoded.parentImageID == nil)
        #expect(decoded.maskAttachment == nil)
        #expect(decoded.maskGeometry == nil)
        #expect(decoded.provider == nil)
    }

    @Test func expiredTrashPurgesWithoutOpeningTheScreen() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("maipag-trash-purge-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let chatStore = ChatStore(dataDirectory: root)
        let trash = TrashStore(dataDirectory: root)
        let chat = Chat(title: "Old trash", createdAt: Date(timeIntervalSince1970: 1_000))
        try await chatStore.save(chat)
        try await trash.move(id: chat.id, kind: .chat, title: chat.title, originalPath: ChatStore.relativePath(for: chat.id))
        let records = await trash.list()
        let purgeDate = try #require(records.first?.expiresAt.addingTimeInterval(1))

        let report = await DataHousekeeping(dataDirectory: root).run(now: purgeDate)
        #expect(report.purgedTrashItems == 1)
        #expect(await trash.list().isEmpty)
    }
}
