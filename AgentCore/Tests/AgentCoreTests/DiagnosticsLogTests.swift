import Foundation
import Testing
@testable import AgentCore

@Suite("Private diagnostics")
struct DiagnosticsLogTests {
    @Test func errorsAreRedactedAndDeduplicated() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("maipag-diagnostics-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let data = root.appendingPathComponent("data", isDirectory: true)
        let secret = "ghs_abcdefghijklmnopqrstuvwxyz123456"
        let log = DiagnosticsLog(dataDirectory: data, installIDURL: root.appendingPathComponent("install-id.txt"), secrets: [secret])
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        await log.record(error: ToolInputError("failed with \(secret)"), area: "saving", operation: "upload", path: "chats/a.json", now: now)
        await log.record(error: ToolInputError("failed with \(secret)"), area: "saving", operation: "upload", path: "chats/a.json", now: now.addingTimeInterval(30))
        let entries = await log.recentEntries()
        let entry = try #require(entries.first)

        #expect(entries.count == 1)
        #expect(entry.count == 2)
        #expect(!entry.technical.contains(secret))
        #expect(entry.technical.contains(SensitiveDataRedactor.marker))
    }
}
