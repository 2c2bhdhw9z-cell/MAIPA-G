import Foundation

/// What a tool hands back: text for the model, and short words for the chat.
public struct ToolOutput: Sendable, Hashable {
    public var forModel: String
    /// One short line for the chat, such as "Read README.md".
    public var summary: String
    /// More to show when the line is tapped open.
    public var detail: String?
    public var isError: Bool

    public init(forModel: String, summary: String, detail: String? = nil, isError: Bool = false) {
        self.forModel = forModel
        self.summary = summary
        self.detail = detail
        self.isError = isError
    }
}

/// A capability the AI can use while answering.
public protocol AgentTool: Sendable {
    var name: String { get }
    var spec: ToolSpec { get }
    /// The line shown while the tool runs, such as "Reading README.md…".
    func runningSummary(for arguments: JSONValue) -> String
    func run(arguments: JSONValue, progress: @escaping @Sendable (String) -> Void) async throws -> ToolOutput
}

/// Thrown by a tool when the AI asked for something impossible. The message goes back to the
/// AI so it can correct itself; it is not shown to the user as an error.
public struct ToolInputError: Error, Sendable, CustomStringConvertible {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

extension JSONValue {
    func requiredString(_ key: String) throws -> String {
        guard let value = self[key]?.stringValue, !value.isEmpty else { throw ToolInputError("Missing \"\(key)\".") }
        return value
    }

    func optionalInt(_ key: String) -> Int? {
        if let value = self[key]?.intValue { return value }
        if let text = self[key]?.stringValue { return Int(text) }
        return nil
    }

    func optionalBool(_ key: String) -> Bool? {
        if let value = self[key]?.boolValue { return value }
        if let text = self[key]?.stringValue?.lowercased() { return text == "true" ? true : (text == "false" ? false : nil) }
        return nil
    }

    func optionalString(_ key: String) -> String? {
        guard let value = self[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}

/// Lets the AI stop and ask the user numbered questions with buttons. The agent loop handles it
/// itself: the turn pauses until the user answers.
public enum AskUserTool {
    public static let name = "ask_user"

    public static let spec = ToolSpec(
        name: name,
        description: """
        Ask the person one or more short questions and wait for their answers. Use it only when you \
        need a decision from them, or information you cannot find yourself. Give each question 2 to 6 \
        short, clear choices; the person can also type their own answer. Never ask about something \
        you can work out from the conversation or the repository.
        """,
        parameters: [
            "type": "object",
            "properties": [
                "questions": [
                    "type": "array",
                    "minItems": 1,
                    "maxItems": 6,
                    "items": [
                        "type": "object",
                        "properties": [
                            "question": ["type": "string", "description": "The question, in plain words."],
                            "options": [
                                "type": "array",
                                "minItems": 2,
                                "maxItems": 6,
                                "items": ["type": "string"],
                                "description": "Short answer choices.",
                            ],
                        ],
                        "required": ["question", "options"],
                    ],
                ],
            ],
            "required": ["questions"],
        ]
    )

    /// Reads the questions out of the AI's arguments, forgiving small format slips.
    public static func questions(from arguments: JSONValue) throws -> QuestionSet {
        guard let items = arguments["questions"]?.arrayValue, !items.isEmpty else {
            throw ToolInputError("ask_user needs a \"questions\" list.")
        }
        let questions: [QuestionSet.Question] = items.prefix(6).compactMap { item in
            let text = item["question"]?.stringValue ?? item.stringValue ?? ""
            guard !text.isEmpty else { return nil }
            let options = (item["options"]?.arrayValue ?? []).compactMap(\.stringValue).filter { !$0.isEmpty }
            return QuestionSet.Question(text: text, options: Array(options.prefix(6)))
        }
        guard !questions.isEmpty else { throw ToolInputError("ask_user needs at least one question.") }
        return QuestionSet(questions: questions)
    }
}
