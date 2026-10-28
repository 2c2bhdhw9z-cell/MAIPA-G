import Foundation

/// Which AI a chat uses.
public enum ModelChoice: Sendable, Hashable, Codable, CustomStringConvertible {
    /// MAIPA-G picks an AI for each request, like Kiro's Auto.
    case auto
    /// Only OpenRouter's free AIs.
    case free
    /// One specific OpenRouter model, by id.
    case model(String)

    public static let autoID = "openrouter/auto"
    public static let freeID = "openrouter/free"

    public init(storedValue: String) {
        switch storedValue {
        case "auto": self = .auto
        case "free": self = .free
        default: self = .model(storedValue)
        }
    }

    public var storedValue: String {
        switch self {
        case .auto: return "auto"
        case .free: return "free"
        case .model(let id): return id
        }
    }

    public var description: String { storedValue }

    public init(from decoder: Decoder) throws {
        self.init(storedValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(storedValue)
    }
}

/// The repo and branch a chat works on.
public struct ChatRepo: Codable, Sendable, Hashable {
    public var ref: RepoRef
    public var branch: String
    public var defaultBranch: String
    public var isPrivate: Bool

    public init(ref: RepoRef, branch: String, defaultBranch: String, isPrivate: Bool) {
        self.ref = ref
        self.branch = branch
        self.defaultBranch = defaultBranch
        self.isPrivate = isPrivate
    }
}

/// One conversation. Saved as one JSON file, on the phone and in the user's private data repo.
public struct Chat: Codable, Sendable, Identifiable, Hashable {
    public static let currentFormat = 1

    public var format: Int
    public var id: UUID
    public var title: String
    /// True once the user has renamed the chat, so automatic titles stop replacing it.
    public var titleIsCustom: Bool
    public var createdAt: Date
    public var updatedAt: Date
    public var repo: ChatRepo?
    public var model: ModelChoice
    public var thinking: ThinkingLevel
    public var messages: [ChatMessage]

    public init(
        id: UUID = UUID(),
        title: String = "",
        createdAt: Date = Date(),
        repo: ChatRepo? = nil,
        model: ModelChoice = .auto,
        thinking: ThinkingLevel = .default,
        messages: [ChatMessage] = []
    ) {
        self.format = Self.currentFormat
        self.id = id
        self.title = title
        self.titleIsCustom = false
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.repo = repo
        self.model = model
        self.thinking = thinking
        self.messages = messages
    }

    /// Everything the chat has cost so far, in dollars, as OpenRouter reported it.
    public var totalUsage: Usage {
        messages.compactMap(\.assistantTurn).flatMap(\.steps).compactMap(\.usage).reduce(Usage(), +)
    }

    public var lastAssistantTurn: AssistantTurn? {
        messages.last?.assistantTurn
    }

    /// The first thing the user wrote, for titles and the chat list.
    public var firstUserText: String? {
        messages.lazy.compactMap(\.userText).first
    }

    /// A short excerpt of the latest reply, for the chat list.
    public var preview: String {
        for message in messages.reversed() {
            if let turn = message.assistantTurn, let text = turn.steps.last(where: { !$0.text.isEmpty })?.text {
                return String(text.prefix(160))
            }
            if let text = message.userText { return String(text.prefix(160)) }
        }
        return ""
    }
}

public struct ChatMessage: Codable, Sendable, Identifiable, Hashable {
    public enum Body: Codable, Sendable, Hashable {
        case user(UserMessage)
        case assistant(AssistantTurn)
    }

    public var id: UUID
    public var createdAt: Date
    public var body: Body

    public init(id: UUID = UUID(), createdAt: Date = Date(), body: Body) {
        self.id = id
        self.createdAt = createdAt
        self.body = body
    }

    public static func user(_ text: String) -> ChatMessage {
        ChatMessage(body: .user(UserMessage(text: text)))
    }

    public var userText: String? {
        if case .user(let message) = body { return message.text }
        return nil
    }

    public var assistantTurn: AssistantTurn? {
        get {
            if case .assistant(let turn) = body { return turn }
            return nil
        }
        set {
            if let newValue { body = .assistant(newValue) }
        }
    }
}

public struct UserMessage: Codable, Sendable, Hashable {
    public var text: String
    public init(text: String) { self.text = text }
}

/// Everything the AI did in answer to one user message: one step per request to the model.
public struct AssistantTurn: Codable, Sendable, Hashable {
    public enum Status: String, Codable, Sendable {
        case running
        case done
        /// Stopped by the user, or cut off when the app closed.
        case stopped
        /// The AI asked questions and is waiting for the answers.
        case waitingForUser
        case failed
    }

    public var status: Status
    public var steps: [AssistantStep]
    public var failure: TurnFailure?
    /// Short notes about what happened along the way, shown under the reply.
    public var notices: [String]
    /// How the AI was chosen for this turn, such as "Auto · medium".
    public var routeLabel: String?

    public init(status: Status = .running, steps: [AssistantStep] = [], failure: TurnFailure? = nil, notices: [String] = [], routeLabel: String? = nil) {
        self.status = status
        self.steps = steps
        self.failure = failure
        self.notices = notices
        self.routeLabel = routeLabel
    }

    /// The AIs that answered, in order, without repeats.
    public var modelsUsed: [String] {
        var seen: [String] = []
        for model in steps.compactMap(\.model) where !seen.contains(model) { seen.append(model) }
        return seen
    }

    public var usage: Usage { steps.compactMap(\.usage).reduce(Usage(), +) }

    /// The question set the AI is waiting on, if any.
    public var pendingQuestions: (stepIndex: Int, callIndex: Int, questions: QuestionSet)? {
        guard status == .waitingForUser else { return nil }
        for (stepIndex, step) in steps.enumerated().reversed() {
            for (callIndex, call) in step.toolCalls.enumerated() where call.status == .waitingForUser {
                if let questions = call.questions { return (stepIndex, callIndex, questions) }
            }
        }
        return nil
    }
}

/// Why a turn did not finish, in words for the user, plus what they can do about it.
public struct TurnFailure: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable {
        case outOfCredits
        case freeLimitReached
        case signInNeeded
        case offline
        case tooLong
        case stepLimit
        case providerFailed
        case other
    }

    public var kind: Kind
    public var message: String
    /// Raw detail for Settings, Technical details.
    public var detail: String?

    public init(kind: Kind, message: String, detail: String? = nil) {
        self.kind = kind
        self.message = message
        self.detail = detail
    }
}

/// One request to the model and what came back.
public struct AssistantStep: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var startedAt: Date
    public var finishedAt: Date?
    /// The AI that actually answered (for Auto, the one it picked).
    public var model: String?
    public var text: String
    public var reasoning: String
    /// The model's thinking blocks, kept exactly as received so they can be sent back.
    public var reasoningDetails: [JSONValue]
    public var toolCalls: [ToolCallRecord]
    public var usage: Usage?
    public var finishReason: String?

    public init(id: UUID = UUID(), startedAt: Date = Date()) {
        self.id = id
        self.startedAt = startedAt
        self.finishedAt = nil
        self.model = nil
        self.text = ""
        self.reasoning = ""
        self.reasoningDetails = []
        self.toolCalls = []
        self.usage = nil
        self.finishReason = nil
    }

    /// How long the model thought, when it shared its thinking.
    public var thinkingSeconds: Int? {
        guard !reasoning.isEmpty, let finishedAt else { return nil }
        return max(1, Int(finishedAt.timeIntervalSince(startedAt).rounded()))
    }
}

/// One tool the AI used, what it was asked, and what it found.
public struct ToolCallRecord: Codable, Sendable, Hashable, Identifiable {
    public enum Status: String, Codable, Sendable { case running, done, failed, waitingForUser }

    public var id: String
    public var name: String
    /// The arguments as JSON text, exactly as the model wrote them.
    public var arguments: String
    public var status: Status
    /// One short line for the chat, such as "Read README.md".
    public var summary: String
    /// More to show when the line is tapped open.
    public var detail: String?
    /// What was sent back to the model.
    public var result: String?
    public var questions: QuestionSet?
    public var startedAt: Date
    public var finishedAt: Date?

    public init(id: String, name: String, arguments: String, summary: String, status: Status = .running, startedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.arguments = arguments
        self.status = status
        self.summary = summary
        self.detail = nil
        self.result = nil
        self.questions = nil
        self.startedAt = startedAt
        self.finishedAt = nil
    }

    public var parsedArguments: JSONValue { JSONValue.parse(arguments) ?? .object([:]) }
}

/// Numbered questions the AI asked, each with a few choices.
public struct QuestionSet: Codable, Sendable, Hashable {
    public struct Question: Codable, Sendable, Hashable {
        public var text: String
        public var options: [String]
        public init(text: String, options: [String]) {
            self.text = text
            self.options = options
        }
    }

    public var questions: [Question]
    /// One answer per question once the user has answered.
    public var answers: [String]?

    public init(questions: [Question], answers: [String]? = nil) {
        self.questions = questions
        self.answers = answers
    }

    /// The answers in a form the model reads easily.
    public var answerText: String? {
        guard let answers else { return nil }
        return zip(questions.indices, questions).map { index, question in
            let answer = index < answers.count ? answers[index] : "(no answer)"
            return "\(index + 1). \(question.text)\nAnswer: \(answer)"
        }.joined(separator: "\n\n")
    }
}
