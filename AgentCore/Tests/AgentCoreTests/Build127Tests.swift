import Foundation
import Testing
@testable import AgentCore

@Suite("Build 127 — visible truncation, silent attachment drops, and restart-settled workflow runs")
struct Build127Tests {
    private var utc: TimeZone { TimeZone(identifier: "UTC") ?? TimeZone.current }

    @Test("A long diff is cut with a visible warning instead of ending silently")
    func cappedDiffWarns() {
        let short = String(repeating: "a", count: 100)
        #expect(ChangeWorkspace.capped(short, limit: 200, hint: "hint") == short)

        let long = String(repeating: "b", count: 500)
        let cut = ChangeWorkspace.capped(long, limit: 200, hint: "Use read_file to see the rest of the file.")
        #expect(cut.hasPrefix(String(repeating: "b", count: 200)))
        #expect(cut.contains("[WARNING: Output truncated at 200 characters."))
        #expect(cut.contains("Use read_file to see the rest of the file."))
        #expect(cut.count > 200)
    }

    @Test("A skipped attachment is named in the system prompt so the AI cannot pretend it read it")
    func skippedAttachmentsReachSystemPrompt() {
        let plain = SystemPrompt.make(now: Date(), timeZone: utc, userLogin: "someone", repo: nil)
        #expect(!plain.contains("could NOT be sent"))

        let noted = SystemPrompt.make(
            now: Date(),
            timeZone: utc,
            userLogin: "someone",
            repo: nil,
            skippedAttachments: ["huge.pdf"]
        )
        #expect(noted.contains("could NOT be sent"))
        #expect(noted.contains("huge.pdf"))
        #expect(noted.contains("Never claim to have read them"))
    }

    @Test("A user message exposes its own attachments for the pure image turn")
    func userMessageExposesAttachments() {
        let reference = AttachmentReference(
            name: "photo.jpg",
            mimeType: "image/jpeg",
            kind: .image,
            path: "attachments/x/photo.jpg",
            bytes: 12
        )
        let message = ChatMessage.user("make it blue", attachments: [reference])
        #expect(message.userAttachments.map(\.name) == ["photo.jpg"])
        #expect(ChatMessage.user("no files").userAttachments.isEmpty)
        #expect(ChatMessage(body: .assistant(AssistantTurn())).userAttachments.isEmpty)
    }
}
