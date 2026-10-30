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
