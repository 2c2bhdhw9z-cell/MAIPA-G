import Foundation
import Testing
@testable import AgentCore

@Suite("Recently Deleted")
struct TrashStoreTests {
    @Test func movesRestoresAndPermanentlyDeletesRecords() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("maipag-trash-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let chats = ChatStore(dataDirectory: root)
        let trash = TrashStore(dataDirectory: root)
        let chat = Chat(title: "Keep me")
        try await chats.save(chat)
        let path = ChatStore.relativePath(for: chat.id)

        try await trash.move(id: chat.id, kind: .chat, title: chat.title, originalPath: path)
        #expect(await chats.load(chat.id) == nil)
        let entry = try #require(await trash.list().first)
        #expect(entry.title == "Keep me")
        #expect(entry.expiresAt > entry.deletedAt)

        try await trash.restore(entry)
        #expect(await chats.load(chat.id)?.title == "Keep me")
        #expect(await trash.list().isEmpty)

        try await trash.move(id: chat.id, kind: .chat, title: chat.title, originalPath: path)
        let movedAgain = try #require(await trash.list().first)
        try await trash.deleteForever(movedAgain)
        #expect(await trash.list().isEmpty)
        #expect(await chats.load(chat.id) == nil)
    }
}
