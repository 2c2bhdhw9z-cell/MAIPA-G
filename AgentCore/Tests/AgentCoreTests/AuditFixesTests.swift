import Foundation
import Testing
@testable import AgentCore

@Suite("Full Debug Audit Fixes — S1/S2/S3 Crash, Sync Integrity, Process Deadlock, Turnstile & Shell Safety")
struct AuditFixesTests {

    @Test("2.1 SensitiveDataRedactor.redactJSON preserves exact bytes on clean JSON while redacting real secrets")
    func redactJSONPreservesCleanBytes() throws {
        let raw = Data(#"{ "z_key": 1,   "a_key": "discussing OAuth PKCE flow without real tokens" }"#.utf8)
        let out = try SensitiveDataRedactor().redactJSON(raw)
        #expect(out == raw)

        let dirty = Data(#"{"note":"sk-or-v1-1234567890abcdefghijklmnop"}"#.utf8)
        let cleaned = try SensitiveDataRedactor().redactJSON(dirty)
        #expect(cleaned != dirty)
        #expect(String(decoding: cleaned, as: UTF8.self).contains(SensitiveDataRedactor.marker))
    }

    @Test("3.1 WorkspaceTurnstile evicts cancelled waiters without running their body")
    func turnstileEvictsCancelledWaiter() async throws {
        let turnstile = WorkspaceTurnstile()
        actor Counter {
            var ranSecond = false
            func markRan() { ranSecond = true }
        }
        let counter = Counter()
        let entered = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()

        let holder = Task {
            try await turnstile.run {
                entered.continuation.yield(())
                var it = release.stream.makeAsyncIterator()
                _ = await it.next()
            }
        }
        var enterIt = entered.stream.makeAsyncIterator()
        _ = await enterIt.next()

        let cancelledWaiter = Task {
            try await turnstile.run {
                await counter.markRan()
            }
        }
        try await Task.sleep(nanoseconds: 30_000_000)
        cancelledWaiter.cancel()
        await #expect(throws: CancellationError.self) {
            try await cancelledWaiter.value
        }

        release.continuation.yield(())
        try await holder.value
        #expect(await counter.ranSecond == false)
    }

    @Test("3.2 BoundedProcess handles >256 KiB stdin payloads without pipe buffer deadlock")
    func boundedProcessLargeStdinNoDeadlock() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("maipag-stdin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let largePayload = Data(repeating: UInt8(ascii: "x"), count: 512 * 1024)
        let res = try await BoundedProcess.run(
            executable: "/usr/bin/wc",
            arguments: ["-c"],
            directory: tempDir,
            stdin: largePayload,
            timeout: 10
        )
        #expect(res.exitCode == 0)
        #expect(res.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "\(512 * 1024)")
    }

    @Test("5.2 & 5.3 ProcessTool blocks unsafe git flags and WorkspaceInspectTool accepts '.' as root")
    func gitFlagApprovalAndInspectWorkspaceDotRoot() async throws {
        #expect(ProcessTool.needsApproval("git status") == false)
        #expect(ProcessTool.needsApproval("git diff HEAD~1") == false)
        #expect(ProcessTool.needsApproval("git show --output=/tmp/pwn HEAD:README.md") == true)
        #expect(ProcessTool.needsApproval("git diff --no-index /etc/hosts /dev/null") == true)
        #expect(ProcessTool.needsApproval("git diff --ext-diff") == true)
        #expect(ProcessTool.needsApproval("git -c core.pager=sh log") == true)

        let tempRepo = FileManager.default.temporaryDirectory.appendingPathComponent("maipag-dot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRepo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRepo) }
        try Data("hello".utf8).write(to: tempRepo.appendingPathComponent("README.md"))

        let inspect = WorkspaceInspectTool(directory: tempRepo)
        let listed = try await inspect.run(arguments: ["operation": "list", "path": "."]) { _ in }
        #expect(listed.forModel.contains("README.md"))
    }

    @Test("5.1 & 2.3 Transcript.fit omits a single >9 MB inline attachment and preserves compactedSummary across rewind")
    func singleOversizedAttachmentOmittedAndSummaryPreserved() {
        let hugeBase64 = "data:application/pdf;base64," + String(repeating: "A", count: 10_000_000)
        let messages: [APIMessage] = [
            .system("You are helpful."),
            APIMessage(
                role: .user,
                content: nil,
                contentParts: [
                    ["type": "text", "text": "Read this giant PDF"],
                    ["type": "file", "file": ["filename": "huge.pdf", "file_data": .string(hugeBase64)]]
                ]
            )
        ]
        let (fitted, trimmed) = Transcript.fit(messages, budget: 200_000, maxPayloadBytes: Transcript.defaultMaxPayloadBytes)
        #expect(trimmed == true)
        #expect(Transcript.estimatedWireBytes(fitted) < Transcript.defaultMaxPayloadBytes)
        let serialized = fitted.last?.contentParts?.map { $0.jsonString() }.joined(separator: " ") ?? ""
        #expect(serialized.contains("huge.pdf"))
        #expect(serialized.contains("read_attachment"))

        var chat = Chat(model: .auto)
        chat.compactedSummary = "# Current State\nPreserved summary."
        chat.compactedThroughMessageID = UUID() // Missing/rewound ID
        chat.messages = [.user("Continue working")]
        let built = Transcript.messages(for: chat, systemPrompt: "System")
        #expect(built.first?.content?.contains("Preserved summary.") == true)
    }

    @Test("2.5 BackgroundCommandRegistry marks stopped commands immediately as non-error stopped")
    func backgroundCommandStopImmediate() async throws {
        let registry = BackgroundCommandRegistry()
        let id = try await registry.start {
            try await Task.sleep(nanoseconds: 10_000_000_000)
            return ToolOutput(forModel: "done", summary: "done")
        }
        let stopped = await registry.stop(id)
        #expect(stopped.isError == false)
        let status = await registry.status(id)
        #expect(status.isError == false)
        #expect(status.forModel.localizedCaseInsensitiveContains("stopped"))
    }
}
