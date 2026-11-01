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
    public static let currentFormat = 3

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
    /// Optional user-created group. nil keeps Build 1 chats ungrouped.
    public var groupID: UUID?
    /// Receipts for saves made from this chat. The last eligible receipt powers Undo.
    public var saveReceipts: [SaveReceipt]?
    /// Durable links used by later job, workflow and spec coordinators.
    public var activeJobID: UUID?
    public var workflowID: UUID?
    public var specID: UUID?
    /// Enabled memories captured when this chat began. Existing chats do not change underneath the user.
    public var memoryContext: [String]
    /// Optional Kiro-style compact summary; older messages remain visible but are replaced by this
    /// summary in later model requests.
    public var compactedSummary: String?
    public var compactedThroughMessageID: UUID?
    /// Previous compaction snapshot before the latest `compact()`, enabling one-tap Undo / Restore full memory.
    public var previousCompactedSummary: String?
    public var previousCompactedThroughMessageID: UUID?

    public init(
        id: UUID = UUID(),
        title: String = "",
        createdAt: Date = Date(),
        repo: ChatRepo? = nil,
        model: ModelChoice = .auto,
        thinking: ThinkingLevel = .default,
        messages: [ChatMessage] = [],
        groupID: UUID? = nil,
        memoryContext: [String] = []
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
        self.groupID = groupID
        self.saveReceipts = nil
        self.activeJobID = nil
        self.workflowID = nil
        self.specID = nil
        self.memoryContext = memoryContext
        self.compactedSummary = nil
        self.compactedThroughMessageID = nil
        self.previousCompactedSummary = nil
        self.previousCompactedThroughMessageID = nil
    }

    enum CodingKeys: String, CodingKey {
        case format, id, title, titleIsCustom, createdAt, updatedAt, repo, model, thinking, messages
        case groupID, saveReceipts, activeJobID, workflowID, specID, memoryContext
        case compactedSummary, compactedThroughMessageID
        case previousCompactedSummary, previousCompactedThroughMessageID
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        format = try c.decodeIfPresent(Int.self, forKey: .format) ?? 1
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        titleIsCustom = try c.decodeIfPresent(Bool.self, forKey: .titleIsCustom) ?? false
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        repo = try c.decodeIfPresent(ChatRepo.self, forKey: .repo)
        model = try c.decodeIfPresent(ModelChoice.self, forKey: .model) ?? .auto
        thinking = try c.decodeIfPresent(ThinkingLevel.self, forKey: .thinking) ?? .default
        messages = try c.decodeIfPresent([ChatMessage].self, forKey: .messages) ?? []
        groupID = try c.decodeIfPresent(UUID.self, forKey: .groupID)
        saveReceipts = try c.decodeIfPresent([SaveReceipt].self, forKey: .saveReceipts)
        activeJobID = try c.decodeIfPresent(UUID.self, forKey: .activeJobID)
        workflowID = try c.decodeIfPresent(UUID.self, forKey: .workflowID)
        specID = try c.decodeIfPresent(UUID.self, forKey: .specID)
        memoryContext = try c.decodeIfPresent([String].self, forKey: .memoryContext) ?? []
        compactedSummary = try c.decodeIfPresent(String.self, forKey: .compactedSummary)
        compactedThroughMessageID = try c.decodeIfPresent(UUID.self, forKey: .compactedThroughMessageID)
        previousCompactedSummary = try c.decodeIfPresent(String.self, forKey: .previousCompactedSummary)
        previousCompactedThroughMessageID = try c.decodeIfPresent(UUID.self, forKey: .previousCompactedThroughMessageID)
    }

    /// Everything the chat has cost so far, in dollars, as OpenRouter reported it.
    public var totalUsage: Usage {
        var usage = messages.compactMap(\.assistantTurn).flatMap(\.steps).compactMap(\.usage).reduce(Usage(), +)
        let steps = messages.compactMap(\.assistantTurn).flatMap(\.steps)
        let extraCosts = steps.flatMap { $0.generatedImages ?? [] }.compactMap(\.cost) + steps.flatMap(\.toolCalls).compactMap(\.billedCost)
        if !extraCosts.isEmpty { usage.cost = (usage.cost ?? 0) + extraCosts.reduce(0, +) }
        return usage
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
    public var starredMemoryID: UUID?

    public init(id: UUID = UUID(), createdAt: Date = Date(), body: Body, starredMemoryID: UUID? = nil) {
        self.id = id
        self.createdAt = createdAt
        self.body = body
        self.starredMemoryID = starredMemoryID
    }

    enum CodingKeys: String, CodingKey { case id, createdAt, body, starredMemoryID }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        body = try c.decode(Body.self, forKey: .body)
        starredMemoryID = try c.decodeIfPresent(UUID.self, forKey: .starredMemoryID)
    }

    public static func user(_ text: String, attachments: [AttachmentReference] = []) -> ChatMessage {
        ChatMessage(body: .user(UserMessage(text: text, attachments: attachments)))
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

public enum AttachmentKind: String, Codable, Sendable, Hashable {
    case image, pdf, text, file
}

/// A durable attachment. `path` is relative to MAIPA-G's mirrored data folder.
public struct AttachmentReference: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    public var mimeType: String
    public var kind: AttachmentKind
    public var path: String
    public var bytes: Int
    public var createdAt: Date

    public init(id: UUID = UUID(), name: String, mimeType: String, kind: AttachmentKind, path: String, bytes: Int, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.mimeType = mimeType
        self.kind = kind
        self.path = path
        self.bytes = bytes
        self.createdAt = createdAt
    }
}

public struct UserMessage: Codable, Sendable, Hashable {
    public var text: String
    public var attachments: [AttachmentReference]

    public init(text: String, attachments: [AttachmentReference] = []) {
        self.text = text
        self.attachments = attachments
    }

    enum CodingKeys: String, CodingKey { case text, attachments }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try c.decode(String.self, forKey: .text)
        attachments = try c.decodeIfPresent([AttachmentReference].self, forKey: .attachments) ?? []
    }
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
    /// Set when the turn paused because it reached the "stop and ask" amount: what it had cost.
    public var spendCheck: Double?
    /// After the user said "keep going", the turn may spend up to this before asking again.
    public var approvedSpendUpTo: Double?

    public init(status: Status = .running, steps: [AssistantStep] = [], failure: TurnFailure? = nil, notices: [String] = [], routeLabel: String? = nil) {
        self.status = status
        self.steps = steps
        self.failure = failure
        self.notices = notices
        self.routeLabel = routeLabel
        self.spendCheck = nil
        self.approvedSpendUpTo = nil
    }

    /// The AIs that answered, in order, without repeats.
    public var modelsUsed: [String] {
        var seen: [String] = []
        for model in steps.compactMap(\.model) where !seen.contains(model) { seen.append(model) }
        return seen
    }

    public var usage: Usage {
        var usage = steps.compactMap(\.usage).reduce(Usage(), +)
        let extraCosts = steps.flatMap { $0.generatedImages ?? [] }.compactMap(\.cost) + steps.flatMap(\.toolCalls).compactMap(\.billedCost)
        if !extraCosts.isEmpty { usage.cost = (usage.cost ?? 0) + extraCosts.reduce(0, +) }
        return usage
    }

    /// The question set the AI is waiting on, if any.
    public var pendingQuestions: (stepIndex: Int, callIndex: Int, questions: QuestionSet)? {
        guard status == .waitingForUser, spendCheck == nil else { return nil }
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

public struct SourceCitation: Codable, Sendable, Hashable, Identifiable {
    public var url: String
    public var title: String?
    public var id: String { url }
    public init(url: String, title: String? = nil) { self.url = url; self.title = title }
}

public struct GeneratedImageResult: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID { attachment.id }
    public var attachment: AttachmentReference
    public var prompt: String
    public var model: String
    public var aspectRatio: String
    public var quality: String
    public var cost: Double?
    public init(attachment: AttachmentReference, prompt: String, model: String, aspectRatio: String, quality: String, cost: Double? = nil) {
        self.attachment = attachment; self.prompt = prompt; self.model = model
        self.aspectRatio = aspectRatio; self.quality = quality; self.cost = cost
    }
}

/// One request to the model and what came back.
public struct AssistantStep: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var startedAt: Date
    public var finishedAt: Date?
    /// Timestamp when reasoning finished and visible text/tool output began, for accurate "Thought for Ns".
    public var reasoningFinishedAt: Date?
    /// The AI that actually answered (for Auto, the one it picked).
    public var model: String?
    public var text: String
    public var reasoning: String
    /// The model's thinking blocks, kept exactly as received so they can be sent back.
    public var reasoningDetails: [JSONValue]
    public var toolCalls: [ToolCallRecord]
    public var usage: Usage?
    public var finishReason: String?
    /// Web sources returned by OpenRouter server tools.
    public var citations: [SourceCitation]?
    /// Real generated media saved under media/, retained through chat sync.
    public var generatedImages: [GeneratedImageResult]?

    public init(id: UUID = UUID(), startedAt: Date = Date()) {
        self.id = id
        self.startedAt = startedAt
        self.finishedAt = nil
        self.reasoningFinishedAt = nil
        self.model = nil
        self.text = ""
        self.reasoning = ""
        self.reasoningDetails = []
        self.toolCalls = []
        self.usage = nil
        self.finishReason = nil
        self.citations = nil
        self.generatedImages = nil
    }

    /// How long the model thought, when it shared its thinking.
    public var thinkingSeconds: Int? {
        guard !reasoning.isEmpty, let end = reasoningFinishedAt ?? finishedAt else { return nil }
        return max(1, Int(end.timeIntervalSince(startedAt).rounded()))
    }
}

/// Live and persisted state for a single Kiro-style sub-agent launched via `launch_helpers`.
public struct SubagentRunItem: Codable, Sendable, Hashable, Identifiable {
    public enum Status: String, Codable, Sendable {
        case running
        case completed
        case cancelled
        case failed
    }

    public var id: String
    public var agentID: String
    public var name: String
    public var task: String
    public var model: String?
    public var status: Status
    public var toolCallCount: Int
    public var latestActivity: String?
    public var toolSummaries: [String]
    public var liveThought: String?
    public var output: String
    public var cost: Double

    public init(
        id: String,
        agentID: String,
        name: String,
        task: String,
        model: String? = nil,
        status: Status = .running,
        toolCallCount: Int = 0,
        latestActivity: String? = nil,
        toolSummaries: [String] = [],
        liveThought: String? = nil,
        output: String = "",
        cost: Double = 0
    ) {
        self.id = id
        self.agentID = agentID
        self.name = name
        self.task = task
        self.model = model
        self.status = status
        self.toolCallCount = toolCallCount
        self.latestActivity = latestActivity
        self.toolSummaries = toolSummaries
        self.liveThought = liveThought
        self.output = output
        self.cost = cost
    }

    /// Resolves per-sub-agent items from `call.subagents` when present, or reconstructs them from
    /// `call.parsedArguments["helpers"]` so sub-agent cards are immediately expandable from t=0ms
    /// and for older saved chats that predate structured `subagents` persistence.
    public static func resolvedItems(for call: ToolCallRecord) -> [SubagentRunItem] {
        if let stored = call.subagents, !stored.isEmpty {
            guard call.status != .running && call.status != .waitingForUser else { return stored }
            return stored.map { item in
                guard item.status == .running else { return item }
                var copy = item
                copy.status = fallbackTerminalStatus(for: call)
                return copy
            }
        }
        guard call.name == "launch_helpers",
              let helpers = call.parsedArguments["helpers"]?.arrayValue,
              !helpers.isEmpty
        else { return [] }

        let status: Status = {
            switch call.status {
            case .running, .waitingForUser:
                return .running
            case .done:
                return call.summary.localizedCaseInsensitiveContains("cancelled") ? .cancelled : .completed
            case .failed:
                return fallbackTerminalStatus(for: call)
            }
        }()

        let legacySections: [String] = {
            guard let detail = call.detail, !detail.isEmpty, detail != "Stopped" else { return [] }
            return detail.components(separatedBy: "\n\n---\n\n")
        }()

        return helpers.enumerated().map { index, entry in
            let agentID = entry["agent_id"]?.stringValue ?? "sub-agent"
            let name = BuiltInAgents.named(agentID)?.name ?? agentID
            let task = entry["task"]?.stringValue ?? ""
            let fallbackOutput: String = {
                if index < legacySections.count { return legacySections[index] }
                if helpers.count == 1, let r = call.result, !r.isEmpty { return r }
                return ""
            }()
            return SubagentRunItem(
                id: "\(call.id)-sub-\(index)",
                agentID: agentID,
                name: name,
                task: task,
                status: status,
                output: fallbackOutput
            )
        }
    }

    private static func fallbackTerminalStatus(for call: ToolCallRecord) -> Status {
        let combined = "\(call.summary) \(call.detail ?? "")".lowercased()
        if combined.contains("cancel") || combined.contains("stopped") || combined.contains("interrupted") {
            return .cancelled
        }
        if call.detail == nil && call.result == nil {
            return .cancelled
        }
        return call.status == .done ? .completed : .failed
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
    /// Dollars a tool cost outside the AI request, such as measured chat-computer time.
    public var billedCost: Double?
    /// Structured per-sub-agent live and completed states when `name == "launch_helpers"`.
    public var subagents: [SubagentRunItem]?

    public init(
        id: String,
        name: String,
        arguments: String,
        summary: String,
        status: Status = .running,
        startedAt: Date = Date(),
        subagents: [SubagentRunItem]? = nil
    ) {
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
        self.subagents = subagents
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
