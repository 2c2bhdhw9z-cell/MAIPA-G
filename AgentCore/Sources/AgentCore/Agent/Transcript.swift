import Foundation

/// Turns a saved chat into the message list a model reads, and keeps that list within budget.
public enum Transcript {
    static let interruptedToolResult = "This tool did not finish: the person stopped the reply or the app closed. Run it again if you still need it."
    static let unansweredQuestions = "The person did not answer these questions and wrote a new message instead."
    static let trimmedToolResult = "[Earlier tool output removed to save space. Run the tool again if you need it.]"

    /// The messages for the next request: the system prompt, then the whole conversation.
    ///
    /// Every tool call gets a result, because the API rejects a call left without one: calls that
    /// never finished get a short note instead. Thinking blocks are sent back only for the turn in
    /// progress, which is where models need them to carry on mid-answer; older ones would only
    /// cost tokens.
    public static func messages(for chat: Chat, systemPrompt: String) -> [APIMessage] {
        var result: [APIMessage] = [.system(systemPrompt)]
        let lastAssistantIndex = chat.messages.lastIndex { $0.assistantTurn != nil }
        for (index, message) in chat.messages.enumerated() {
            switch message.body {
            case .user(let user):
                result.append(.user(user.text))
            case .assistant(let turn):
                let isCurrent = index == lastAssistantIndex && index == chat.messages.count - 1
                for step in turn.steps {
                    let calls = step.toolCalls
                    let text = step.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty || !calls.isEmpty else { continue }
                    result.append(APIMessage(
                        role: .assistant,
                        content: text.isEmpty ? nil : step.text,
                        toolCalls: calls.isEmpty ? nil : calls.map { APIToolCall(id: $0.id, name: $0.name, arguments: $0.arguments) },
                        reasoningDetails: isCurrent && !step.reasoningDetails.isEmpty ? step.reasoningDetails : nil
                    ))
                    for call in calls {
                        result.append(.tool(id: call.id, toolResultText(for: call, turnIsCurrent: isCurrent)))
                    }
                }
            }
        }
        return result
    }

    static func toolResultText(for call: ToolCallRecord, turnIsCurrent: Bool) -> String {
        if let result = call.result { return result }
        if let answers = call.questions?.answerText { return answers }
        if call.name == AskUserTool.name { return unansweredQuestions }
        return interruptedToolResult
    }

    /// A rough token count: about 3.6 characters per token for English and code.
    public static func estimatedTokens(_ messages: [APIMessage]) -> Int {
        var characters = 0
        for message in messages {
            characters += message.content?.count ?? 0
            characters += message.toolCalls?.reduce(0) { $0 + $1.function.arguments.count + $1.function.name.count + 16 } ?? 0
            characters += 12
        }
        return Int(Double(characters) / 3.6)
    }

    /// Shrinks the list until it fits `budget` tokens. Old tool output goes first (the AI can run
    /// the tool again); then, if still too long, the oldest exchanges, never the system prompt or
    /// the latest user message and what followed it.
    public static func fit(_ messages: [APIMessage], budget: Int) -> (messages: [APIMessage], trimmed: Bool) {
        var messages = messages
        guard estimatedTokens(messages) > budget else { return (messages, false) }
        let protectedFrom = messages.lastIndex { $0.role == .user } ?? messages.count
        for index in messages.indices where index < protectedFrom && messages[index].role == .tool {
            if (messages[index].content?.count ?? 0) > trimmedToolResult.count {
                messages[index].content = trimmedToolResult
            }
            if estimatedTokens(messages) <= budget { return (messages, true) }
        }
        // Then drop whole exchanges from the front: a user message and everything up to the next
        // one. The latest exchange always stays.
        var dropped = false
        while estimatedTokens(messages) > budget {
            guard let firstUser = messages.firstIndex(where: { $0.role == .user }),
                  let lastUser = messages.lastIndex(where: { $0.role == .user }),
                  firstUser < lastUser,
                  let nextUser = messages[(firstUser + 1)...].firstIndex(where: { $0.role == .user })
            else { break }
            messages.removeSubrange(firstUser..<nextUser)
            dropped = true
        }
        if dropped, let system = messages.first, system.role == .system {
            messages[0].content = (system.content ?? "") + "\n\nEarlier parts of this conversation were left out to save space."
        }
        return (messages, true)
    }
}
