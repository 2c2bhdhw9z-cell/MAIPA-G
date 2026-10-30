import Foundation
import Testing
@testable import AgentCore

@Suite("Saved-data housekeeping")
struct JobCompactionTests {
    @Test func oldFinishedJobsDropRestartPayloadButKeepTheirResult() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("maipag-jobs-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = JobStore(dataDirectory: root)
        var job = JobRecord(
            status: .done,
            title: "Finished",
            state: ["request": "do work", "workflowCheckpoint": ["large": .string(String(repeating: "x", count: 20_000))], "workspacePatch": "patch"],
            result: JobResult(summary: "Done")
        )
        job = try await store.checkpoint(job, at: Date(timeIntervalSince1970: 1_000))

        #expect(try await store.compactFinished(now: Date(timeIntervalSince1970: 1_000 + 15 * 24 * 60 * 60)) == 1)
        let compacted = try #require(await store.load(job.id))
        #expect(compacted.state["workflowCheckpoint"] == nil)
        #expect(compacted.state["workspacePatch"] == nil)
        #expect(compacted.state["request"] == "do work")
        #expect(compacted.state["compactedAt"] != nil)
        #expect(compacted.result?.summary == "Done")
    }
}
