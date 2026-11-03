import Foundation
import Testing
@testable import AgentCore

@Suite("DeepSeek reasoning replay")
struct DeepSeekReasoningTests {
    private func chatWithOlderToolTurn() -> Chat {
        var chat = Chat()
        var toolStep = AssistantStep()
        toolStep.reasoning = "Need to read the file."
        toolStep.reasoningDetails = [["type": "reasoning.text", "text": "Need to read the file."]]
        toolStep.toolCalls = [ToolCallRecord(id: "a", name: "read_file", arguments: "{}", summary: "Reading…")]
        var plainStep = AssistantStep()
        plainStep.text = "Done."
        plainStep.reasoning = "Plain answer thinking."
        chat.messages = [
            .user("one"),
            ChatMessage(body: .assistant(AssistantTurn(status: .done, steps: [toolStep, plainStep]))),
            .user("two"),
        ]
        return chat
    }

    @Test func olderToolCallKeepsThinkingWhenModelNeedsIt() throws {
        let messages = Transcript.messages(for: chatWithOlderToolTurn(), systemPrompt: "s", replaysToolCallReasoning: true)
        let toolCall = try #require(messages.first { $0.toolCalls != nil })
        #expect(toolCall.reasoningContent == "Need to read the file.")
        #expect(toolCall.reasoningDetails?.isEmpty == false)
        // Messages without tool calls are not required to carry it.
        let plain = try #require(messages.first { $0.role == .assistant && $0.content == "Done." })
        #expect(plain.reasoningContent == nil)
        #expect(plain.reasoningDetails == nil)
    }

    @Test func missingThinkingIsSentAsEmptyStringNotOmitted() throws {
        var chat = chatWithOlderToolTurn()
        guard case .assistant(var turn) = chat.messages[1].body else { return }
        turn.steps[0].reasoning = ""
        turn.steps[0].reasoningDetails = []
        chat.messages[1] = ChatMessage(body: .assistant(turn))
        let messages = Transcript.messages(for: chat, systemPrompt: "s", replaysToolCallReasoning: true)
        let toolCall = try #require(messages.first { $0.toolCalls != nil })
        #expect(toolCall.reasoningContent == "")
        let json = try #require(JSONValue.parse(try JSONEncoder().encode(toolCall)))
        #expect(json["reasoning_content"] == "")
    }

    @Test func otherModelsStillDropOlderThinking() throws {
        let messages = Transcript.messages(for: chatWithOlderToolTurn(), systemPrompt: "s")
        let toolCall = try #require(messages.first { $0.toolCalls != nil })
        #expect(toolCall.reasoningContent == nil)
        #expect(toolCall.reasoningDetails == nil)
    }

    @Test func detectsDeepSeekModelsThroughGateways() {
        #expect(Transcript.requiresToolCallReasoningReplay(model: "oneprovider::deepseek-v4-pro"))
        #expect(Transcript.requiresToolCallReasoningReplay(model: "deepseek/deepseek-v4"))
        #expect(!Transcript.requiresToolCallReasoningReplay(model: "oneprovider::claude-sonnet-5-5"))
    }
}
