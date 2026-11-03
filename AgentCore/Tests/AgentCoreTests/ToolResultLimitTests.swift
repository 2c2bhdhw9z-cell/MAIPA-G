import Foundation
import Testing
@testable import AgentCore

@Suite("Tool result payload limit")
struct ToolResultLimitTests {
    @Test func capIncludesNoticeAndPreservesSmallResults() {
        for count in [0, 19_999, 20_000, 20_001, 200_000] {
            let text = String(repeating: "x", count: count)
            let capped = Transcript.cappedToolResult(text)
            #expect(capped.count == min(count, 20_000))
            if count <= 20_000 {
                #expect(capped == text)
            } else {
                #expect(capped.hasSuffix(Transcript.toolResultTruncationNotice))
            }
            #expect(Transcript.cappedToolResult(capped) == capped)
        }
    }

    @Test func capPreservesUnicodeCharacters() {
        let character = "👩🏽‍💻"
        let text = String(repeating: character, count: 20_001)
        let capped = Transcript.cappedToolResult(text)
        #expect(capped.count == 20_000)
        #expect(capped.hasSuffix(Transcript.toolResultTruncationNotice))
        #expect(capped.dropLast(Transcript.toolResultTruncationNotice.count)
            .allSatisfy { String($0) == character })
    }

    @Test func replayCapsCurrentRecentAndOlderResultsIncludingJSONEscaping() throws {
        // Quotes, backslashes and control characters expand when encoded in the envelope.
        for unit in ["x", "\"\\\n\t\u{0000}", "👩🏽‍💻"] {
            let text = String(repeating: unit, count: 80_001)
            var call = ToolCallRecord(id: "large", name: "read_file", arguments: "{}", summary: "Read file")
            call.result = text
            for (current, older) in [(true, false), (false, false), (false, true)] {
                let output = Transcript.toolResultText(for: call, turnIsCurrent: current, isOlderTurn: older)
                #expect(output.count <= 20_000)
                let jsonStart = try #require(output.firstIndex(of: "{"))
                let envelope = try #require(JSONValue.parse(String(output[jsonStart...])))
                #expect(envelope["kind"]?.stringValue == "untrusted_tool_data")
                #expect(envelope["tool"]?.stringValue == "read_file")
                #expect(envelope["content"]?.stringValue?.hasPrefix(unit) == true)
            }
            #expect(call.result == text)
        }
    }

    @Test func oversizedToolNameCannotBypassCap() throws {
        var call = ToolCallRecord(id: "unknown", name: String(repeating: "x", count: 30_000), arguments: "{}", summary: "Unknown tool")
        call.result = "Unknown tool"
        let output = Transcript.toolResultText(for: call, turnIsCurrent: true)
        #expect(output.count <= 20_000)
        let jsonStart = try #require(output.firstIndex(of: "{"))
        #expect(JSONValue.parse(String(output[jsonStart...])) != nil)
    }

    @Test func replayKeepsSmallResultAndInterruptedCall() throws {
        var call = ToolCallRecord(id: "small", name: "read_file", arguments: "{}", summary: "Read file")
        #expect(Transcript.toolResultText(for: call, turnIsCurrent: true) == Transcript.interruptedToolResult)
        call.result = "short \"quoted\" output\n"
        let output = Transcript.toolResultText(for: call, turnIsCurrent: true)
        let jsonStart = try #require(output.firstIndex(of: "{"))
        let envelope = try #require(JSONValue.parse(String(output[jsonStart...])))
        #expect(envelope["content"]?.stringValue == call.result)
    }

    @Test func savedHistoryAndCurrentTurnAreCappedWithIDsIntact() throws {
        var call = ToolCallRecord(id: "history", name: "read_file", arguments: "{}", summary: "Read file")
        call.result = String(repeating: "old", count: 40_000)
        var step = AssistantStep()
        step.toolCalls = [call]
        var turn = AssistantTurn()
        turn.steps = [step]
        var chat = Chat()
        chat.messages = [.user("Read"), ChatMessage(body: .assistant(turn)), .user("Continue")]
        call.id = "current"
        step.toolCalls = [call]
        turn.steps = [step]
        chat.messages.append(ChatMessage(body: .assistant(turn)))
        let messages = Transcript.messages(for: chat, systemPrompt: "system")
        let results = messages.filter { $0.role == .tool }
        #expect(results.count == 2)
        #expect(results.map(\.toolCallID) == ["history", "current"])
        #expect(results.allSatisfy { ($0.content?.count ?? 0) <= 20_000 })
    }

    @Test func liveSuccessAndErrorsAreCappedBeforeNextRequest() async throws {
        for throwsError in [false, true] {
            let transport = ScriptedTransport([
                .events([
                    AgentLoopTests.toolCall(id: "large", name: "large_result", arguments: "{}"),
                    AgentLoopTests.toolsDone,
                ]),
                .events([AgentLoopTests.text("Done"), AgentLoopTests.done]),
            ])
            let text = String(repeating: "\"\\\n", count: 80_000)
            let (turn, _) = await AgentLoopTests.runToEnd(
                transport,
                chat: AgentLoopTests.newChat("Read the output"),
                route: AgentLoopTests.route(),
                tools: [LargeResultTool(text: text, throwsError: throwsError)]
            )
            let finished = try #require(turn)
            #expect(finished.status == .done)
            let call = try #require(finished.steps.first?.toolCalls.first)
            #expect(call.result?.count == 20_000)
            #expect(call.status == (throwsError ? .failed : .done))
            #expect(call.detail == text)
            #expect(transport.requestCount == 2)
            let sent = try #require(transport.sentBodies.last?["messages"]?.arrayValue)
            let result = try #require(sent.first { $0["role"]?.stringValue == "tool" })
            #expect(result["tool_call_id"]?.stringValue == "large")
            let content = try #require(result["content"]?.stringValue)
            #expect(content.count <= 20_000)
            #expect(content.contains("Truncated:"))
        }
    }
}

private struct LargeResultTool: AgentTool {
    let text: String
    let throwsError: Bool
    let name = "large_result"
    var spec: ToolSpec {
        ToolSpec(name: name, description: "Test large output", parameters: ["type": "object"])
    }
    func runningSummary(for arguments: JSONValue) -> String { "Reading output…" }
    func run(arguments: JSONValue, progress: @escaping @Sendable (String) -> Void) async throws -> ToolOutput {
        if throwsError { throw ToolInputError(text) }
        return ToolOutput(forModel: text, summary: "Read output", detail: text)
    }
}
