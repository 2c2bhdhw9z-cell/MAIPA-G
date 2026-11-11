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
    /// Durable Kiro-style Queue follow-ups waiting to run sequentially after the active turn finishes.
    public var queuedFollowUps: [QueuedFollowUp]?
    /// Chat workflow runs, mirrored here so a force-quit app still has them.
    public var activeWorkflowRuns: [ActiveWorkflowRunSnapshot]?
    /// How this chat behaves when you type: Vibe (just do it) or Spec (plan first). Remembered per
    /// chat. Stored as a plain string so AgentCore needs no app-level type.
    public var mode: String?
    /// More repos this chat edits besides `repo`, each with its own branch, staged changes and
    /// save rules. nil for a chat with one repo (or none), which behaves exactly as before.
    public var additionalRepos: [ChatRepo]?
    /// The Kiro-style spec this chat is writing or building (`.kiro/specs/<slug>/` in its repo) and
    /// its phase. nil until Spec mode writes requirements or a `#spec:` reference picks one up.
    public var kiroSpec: KiroSpecState?
    /// The Kiro spec workflow picked for this chat's next spec (Requirements-First when nil).
    public var kiroSpecKind: KiroSpecKind?
    /// Autopilot (nil) or Supervised: whether each change is reviewed before it's saved.
    public var permissionMode: PermissionMode?
    /// Staged changes the person accepted in Supervised review (fingerprints).
    public var acceptedChanges: [String]?
    /// Kiro-style checkpoints, one before each of the person's messages.
    public var checkpoints: [ChatCheckpoint]?
    /// The reply running on the chat computer right now (its run folder there), so a phone that
    /// was closed picks the same run up again instead of starting the reply over.
    public var computerRunID: String?

    /// `repo` first, then the others, without duplicates.
    public var allRepos: [ChatRepo] {
        guard let repo else { return [] }
        var seen: Set<RepoRef> = [repo.ref]
        return [repo] + (additionalRepos ?? []).filter { seen.insert($0.ref).inserted }
    }

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
        self.queuedFollowUps = nil
        self.activeWorkflowRuns = nil
        self.mode = nil
        self.additionalRepos = nil
        self.kiroSpec = nil
        self.kiroSpecKind = nil
        self.permissionMode = nil
        self.acceptedChanges = nil
        self.checkpoints = nil
        self.computerRunID = nil
    }

    enum CodingKeys: String, CodingKey {
        case format, id, title, titleIsCustom, createdAt, updatedAt, repo, model, thinking, messages
        case groupID, saveReceipts, activeJobID, workflowID, specID, memoryContext
        case compactedSummary, compactedThroughMessageID
        case previousCompactedSummary, previousCompactedThroughMessageID
        case queuedFollowUps, activeWorkflowRuns, mode, additionalRepos, kiroSpec
        case kiroSpecKind, permissionMode, acceptedChanges, checkpoints, computerRunID
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
        queuedFollowUps = try c.decodeIfPresent([QueuedFollowUp].self, forKey: .queuedFollowUps)
        activeWorkflowRuns = try c.decodeIfPresent([ActiveWorkflowRunSnapshot].self, forKey: .activeWorkflowRuns)
        mode = try c.decodeIfPresent(String.self, forKey: .mode)
        additionalRepos = try c.decodeIfPresent([ChatRepo].self, forKey: .additionalRepos)
        kiroSpec = try c.decodeIfPresent(KiroSpecState.self, forKey: .kiroSpec)
        kiroSpecKind = try? c.decodeIfPresent(KiroSpecKind.self, forKey: .kiroSpecKind)
        permissionMode = try? c.decodeIfPresent(PermissionMode.self, forKey: .permissionMode)
        acceptedChanges = try c.decodeIfPresent([String].self, forKey: .acceptedChanges)
        checkpoints = (try? c.decodeIfPresent([ChatCheckpoint].self, forKey: .checkpoints)) ?? nil
        computerRunID = try? c.decodeIfPresent(String.self, forKey: .computerRunID)
    }

    /// Everything the chat has cost so far, in dollars, as OpenRouter reported it.
    public var totalUsage: Usage {
        var usage = messages.compactMap(\.assistantTurn).flatMap(\.steps).compactMap(\.usage).reduce(Usage(), +)
        let steps = messages.compactMap(\.assistantTurn).flatMap(\.steps)
        let extraCosts = AssistantStep.extraCosts(steps)
        if !extraCosts.isEmpty { usage.cost = (usage.cost ?? 0) + extraCosts.reduce(0, +) }
        return usage
    }

    /// The chat's headline spend. Each turn counts its real cost (balance before minus balance
    /// after) when both readings exist, and otherwise the cost the provider reported or, failing
    /// that, an estimate from the price list, which marks the whole figure as estimated.
    public var spendSummary: SpendSummary {
        var summary = SpendSummary()
        for turn in messages.compactMap(\.assistantTurn) {
            if let real = turn.realCost {
                summary.dollars = (summary.dollars ?? 0) + real
                summary.realTurns += 1
            } else {
                let usage = turn.usage
                if let cost = usage.cost {
                    summary.dollars = (summary.dollars ?? 0) + cost
                    if usage.costIsEstimate == true { summary.hasEstimate = true }
                } else if let shared = turn.sharedBalanceCost {
                    summary.dollars = (summary.dollars ?? 0) + shared
                }
                // Overlapping turns on one provider can't be told apart in its balance.
                if turn.balanceShared == true { summary.hasEstimate = true }
                if usage.priceUnknown == true, turn.sharedBalanceCost == nil { summary.hasUnknownPrice = true }
            }
        }
        return summary
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

    public var userAttachments: [AttachmentReference] {
        if case .user(let message) = body { return message.attachments }
        return []
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
    /// True when the reply ended some way other than a normal finish (a dropped connection, the
    /// server closing the stream mid-reply). Retry then carries on from where it stopped.
    public var stoppedEarly: Bool?
    /// Total provider balance, in dollars, read just before the turn started.
    public var balanceBefore: Double?
    /// Total provider balance, in dollars, read after the turn ended.
    public var balanceAfter: Double?
    /// Whose balance the two readings are: "openrouter" or a connected gateway's id. Nil on older
    /// turns, whose readings were the total across every provider.
    public var balanceProvider: String?
    /// Another turn on the same provider was running between the two readings, so their
    /// difference includes its spend too and is not this turn's exact cost.
    public var balanceShared: Bool?
    /// Every provider's balance read before and after the turn, by provider id, so a reply that
    /// switched provider partway through is costed on each provider it used.
    public var balancesBefore: [String: Double]?
    public var balancesAfter: [String: Double]?
    /// Every provider any request of this turn went to, including attempts that were retried away.
    public var providersTried: [String]?

    public init(status: Status = .running, steps: [AssistantStep] = [], failure: TurnFailure? = nil, notices: [String] = [], routeLabel: String? = nil) {
        self.status = status
        self.steps = steps
        self.failure = failure
        self.notices = notices
        self.routeLabel = routeLabel
        self.spendCheck = nil
        self.approvedSpendUpTo = nil
    }

    /// What the turn really cost: the provider balance before it minus the balance after it. Nil
    /// until both readings exist. This is what was billed, not a figure from a price list.
    public var realCost: Double? {
        guard balanceShared != true else { return nil }
        return balanceDifference
    }

    /// The balance difference when it was shared with an overlapping turn: an estimate at best.
    public var sharedBalanceCost: Double? {
        guard balanceShared == true else { return nil }
        return balanceDifference
    }

    /// The providers whose balance this turn spent: each step's provider, else the one it started on.
    public var providersUsed: Set<String> {
        var used = Set(steps.compactMap(\.provider) + steps.flatMap { $0.providersTried ?? [] } + (providersTried ?? []))
        if used.isEmpty, let balanceProvider { used.insert(balanceProvider) }
        return used
    }

    /// Per provider: the drop in each provider the turn used, added up. Nil when any of them
    /// lacks a reading. Older turns use the single pair of readings.
    private var balanceDifference: Double? {
        if let before = balancesBefore, let after = balancesAfter {
            let used = providersUsed
            guard !used.isEmpty else { return nil }
            var total = 0.0
            for provider in used {
                guard let start = before[provider], let end = after[provider] else { return nil }
                total += max(0, start - end)
            }
            return total
        }
        guard let before = balanceBefore, let after = balanceAfter else { return nil }
        return max(0, before - after)
    }


    /// The AIs that answered, in order, without repeats.
    public var modelsUsed: [String] {
        var seen: [String] = []
        for model in steps.compactMap(\.model) where !seen.contains(model) { seen.append(model) }
        return seen
    }

    public var usage: Usage {
        var usage = steps.compactMap(\.usage).reduce(Usage(), +)
        let extraCosts = AssistantStep.extraCosts(steps)
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

/// Which turns read the same provider's balance at overlapping times.
///
/// Real spend is a provider's balance before a turn minus after it. Providers can charge a few
/// seconds late, so the app reads again `settleWindow` after the turn. Two turns on one provider
/// whose spans (start to end plus that window) overlap each see the other's spend, so both are
/// marked shared and their figures are shown as estimated. That covers a reply that starts while
/// the previous one's recheck is still pending, which would otherwise leak into it.
public struct BalanceOverlapTracker: Sendable {
    public static let settleWindow: TimeInterval = 20

    private struct Entry: Sendable {
        var providers: Set<String>
        var started: Date
        var ended: Date?
        var shared: Bool
    }

    private var entries: [UUID: Entry] = [:]

    public init() {}

    /// Starts (or resumes) watching a turn on `provider`.
    public mutating func begin(_ turnID: UUID, provider: String, at now: Date = Date()) {
        if var entry = entries[turnID] {
            entry.providers.insert(provider)
            entry.ended = nil
            entries[turnID] = entry
        } else {
            entries[turnID] = Entry(providers: [provider], started: now, ended: nil, shared: false)
        }
        prune(now: now)
        markOverlaps(of: turnID)
    }

    /// Stops watching a turn, adding every provider it ended up using, and says whether another
    /// turn overlapped it on any of them.
    @discardableResult
    public mutating func end(_ turnID: UUID, providers: Set<String> = [], at now: Date = Date()) -> Bool {
        guard var entry = entries[turnID] else { return false }
        entry.providers.formUnion(providers)
        entry.ended = now
        entries[turnID] = entry
        markOverlaps(of: turnID)
        return entries[turnID]?.shared ?? false
    }

    /// True once another turn has overlapped this one, including one that started during its recheck window.
    public func isShared(_ turnID: UUID) -> Bool { entries[turnID]?.shared ?? false }

    /// True while any watched turn is running on `provider`.
    public func isActive(provider: String) -> Bool {
        entries.values.contains { $0.ended == nil && $0.providers.contains(provider) }
    }

    private mutating func markOverlaps(of turnID: UUID) {
        guard let entry = entries[turnID] else { return }
        let window = Self.settleWindow
        for (id, other) in entries where id != turnID && !other.providers.isDisjoint(with: entry.providers) {
            let entryEnd = entry.ended.map { $0.addingTimeInterval(window) } ?? .distantFuture
            let otherEnd = other.ended.map { $0.addingTimeInterval(window) } ?? .distantFuture
            if entry.started < otherEnd && other.started < entryEnd {
                entries[id]?.shared = true
                entries[turnID]?.shared = true
            }
        }
    }

    /// Forgets turns that ended long enough ago that nothing can overlap them any more.
    private mutating func prune(now: Date) {
        entries = entries.filter { _, entry in
            guard let ended = entry.ended else { return true }
            return now.timeIntervalSince(ended) < Self.settleWindow * 15
        }
    }
}

/// A chat's headline spend, with what kind of figure it is.
public struct SpendSummary: Sendable, Equatable {
    /// Dollars, or nil when nothing has a cost yet.
    public var dollars: Double?
    /// Some of it was worked out from a price list rather than billed, so label it "estimated".
    public var hasEstimate: Bool
    /// Some turn used a model with no known price, so the figure leaves that out.
    public var hasUnknownPrice: Bool
    /// Turns whose cost came from real balance readings.
    public var realTurns: Int

    public init(dollars: Double? = nil, hasEstimate: Bool = false, hasUnknownPrice: Bool = false, realTurns: Int = 0) {
        self.dollars = dollars
        self.hasEstimate = hasEstimate
        self.hasUnknownPrice = hasUnknownPrice
        self.realTurns = realTurns
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

/// Durable follow-up message queued via Kiro's `Queue` mode to run sequentially after the active turn completes.
public struct QueuedFollowUp: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var text: String
    public var attachments: [AttachmentReference]
    public var createdAt: Date

    public init(id: UUID = UUID(), text: String, attachments: [AttachmentReference] = [], createdAt: Date = Date()) {
        self.id = id
        self.text = text
        self.attachments = attachments
        self.createdAt = createdAt
    }
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
    /// Money spent outside the AI requests: pictures and videos, and tools that bill (computer
    /// time). A picture's cost is on the picture and also on the tool call that made it; it used
    /// to be added twice.
    public static let mediaTools: Set<String> = ["generate_image", "generate_video"]
    public static func extraCosts(_ steps: [AssistantStep]) -> [Double] {
        steps.flatMap { $0.generatedImages ?? [] }.compactMap(\.cost)
            + steps.flatMap(\.toolCalls).filter { !mediaTools.contains($0.name) }.compactMap(\.billedCost)
    }

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
    /// Live mid-turn Kiro steering notes folded into this step without stopping the running turn.
    public var steeredMessages: [String]?
    /// Where this step's time went, measured, so a slow turn shows its real cause.
    public var timing: StepTiming?
    /// Whose balance this step spent: "openrouter" or a connected gateway's id.
    public var provider: String?
    /// Every provider an attempt at this step went to, including retries that switched provider.
    public var providersTried: [String]?

    public init(id: UUID = UUID(), startedAt: Date = Date(), steeredMessages: [String]? = nil) {
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
        self.steeredMessages = steeredMessages
        self.timing = nil
    }

    /// How long the model thought, when it shared its thinking.
    public var thinkingSeconds: Int? {
        guard !reasoning.isEmpty, let end = reasoningFinishedAt ?? finishedAt else { return nil }
        return max(1, Int(end.timeIntervalSince(startedAt).rounded()))
    }
}

/// Measured timings for one step of a turn, in seconds. Recorded so the next slow turn shows where
/// its time actually went, instead of anyone guessing.
public struct StepTiming: Codable, Sendable, Hashable {
    /// From sending the request to the first piece of the reply arriving.
    public var firstByteSeconds: Double?
    /// From sending the request to the reply stream ending: the whole model call.
    public var modelCallSeconds: Double
    /// The longest gap with nothing arriving while the reply streamed.
    public var longestStallSeconds: Double
    /// Time slept waiting to retry (busy, rate limited, or a dropped connection) before this attempt.
    public var retryWaitSeconds: Double
    /// Requests made for this step, retries included.
    public var attempts: Int
    /// Prompt tokens the provider reported for this step.
    public var promptTokens: Int?
    /// Prompt tokens MAIPA-G estimated it sent (messages plus tool schemas).
    public var sentTokensEstimate: Int
    /// Time spent running this step's tools.
    public var toolSeconds: Double?
    /// Time spent after this step waiting on background sub-agents.
    public var waitingSeconds: Double?

    public init(firstByteSeconds: Double? = nil, modelCallSeconds: Double = 0, longestStallSeconds: Double = 0, retryWaitSeconds: Double = 0, attempts: Int = 1, promptTokens: Int? = nil, sentTokensEstimate: Int = 0, toolSeconds: Double? = nil, waitingSeconds: Double? = nil) {
        self.firstByteSeconds = firstByteSeconds
        self.modelCallSeconds = modelCallSeconds
        self.longestStallSeconds = longestStallSeconds
        self.retryWaitSeconds = retryWaitSeconds
        self.attempts = attempts
        self.promptTokens = promptTokens
        self.sentTokensEstimate = sentTokensEstimate
        self.toolSeconds = toolSeconds
        self.waitingSeconds = waitingSeconds
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
            let helpersStillRunning = stored.contains { $0.status == .running }
            // A helper whose own status is still running was started in the background.
            // The tool's result text is a sentence ("not stopped"), not a status, so it must not decide this.
            if call.status == .running || call.status == .waitingForUser || (call.status == .done && helpersStillRunning) {
                return stored
            }
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

    /// Uses a recorded status value, never a word found inside a sentence.
    /// "not stopped" must not become cancelled. With no recorded terminal status, stay running.
    private static func fallbackTerminalStatus(for call: ToolCallRecord) -> Status {
        if let recorded = exactRecordedStatus(in: call.result) ?? exactRecordedStatus(in: call.detail) {
            return recorded
        }
        switch call.status {
        case .failed:
            return .failed
        case .done, .running, .waitingForUser:
            return .running
        }
    }

    /// The whole text has to be a status, not a sentence that happens to contain one.
    private static func exactRecordedStatus(in text: String?) -> Status? {
        guard let text else { return nil }
        switch text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "cancelled", "canceled", "interrupted", "stopped", "paused",
             "interrupted when the app closed.", "interrupted when the app closed",
             "paused when the app closed.", "paused when the app closed":
            return .cancelled
        case "failed":
            return .failed
        case "completed", "done":
            return .completed
        case "running", "running_in_background":
            return .running
        default:
            return nil
        }
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
    /// A live preview of the app this call started on the chat computer (`app_preview`).
    public var livePreview: LivePreviewLink?

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

/// Where to see an app running live on the chat computer: in MAIPA-G (`webURL`) and, for an
/// Expo app, in Expo Go (`expoGoURL`).
public struct LivePreviewLink: Codable, Sendable, Hashable {
    public var webURL: String
    public var expoGoURL: String?
    /// expo, vite, next, npm or static.
    public var kind: String
    /// The app's folder in the repo, "." for the top.
    public var folder: String
    public var startedAt: Date

    public init(webURL: String, expoGoURL: String? = nil, kind: String, folder: String, startedAt: Date = Date()) {
        self.webURL = webURL; self.expoGoURL = expoGoURL; self.kind = kind; self.folder = folder; self.startedAt = startedAt
    }
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
