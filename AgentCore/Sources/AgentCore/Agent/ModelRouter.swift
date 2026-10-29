import Foundation

/// How hard a request looks, which decides how much Auto may spend on it.
public enum TaskDifficulty: String, Codable, Sendable, CaseIterable {
    /// Chat, quick questions, small jobs.
    case quick
    /// Normal coding and writing.
    case normal
    /// Planning, hard debugging, reviews.
    case hard

    /// OpenRouter's Auto cost band for this difficulty.
    public var costTier: String {
        switch self {
        case .quick: return "low"
        case .normal: return "medium"
        case .hard: return "high"
        }
    }

    /// A quick guess from the words alone, used when the phone's own AI can't judge it.
    public static func estimate(_ message: String, hasRepo: Bool) -> TaskDifficulty {
        let text = message.lowercased()
        let hardSignals = [
            "plan ", "planning", "design", "architect", "debug", "root cause", "why does", "why is", "why do",
            "figure out", "investigate", "review", "audit", "refactor", "optimi", "performance", "security",
            "vulnerab", "race condition", "deadlock", "memory leak", "crash", "trade-off", "tradeoff",
            "compare", "strategy", "migrat", "rewrite", "step by step", "in depth", "thorough",
        ]
        if text.count > 1_200 || hardSignals.contains(where: text.contains) { return .hard }
        let codeSignals = [
            "code", "function", "file", "bug", "error", "fix", "build", "compile", "test", "class", "struct",
            "api", "repo", "branch", "commit", "script", "implement", "add ", "change", "feature", "swift",
            "python", "javascript", "rust", "write ", "draft", "explain",
        ]
        if hasRepo || codeSignals.contains(where: text.contains) { return .normal }
        return text.count < 160 ? .quick : .normal
    }
}

/// Lets the app plug in a better judge of difficulty (the iPhone's own on-device AI).
public protocol DifficultyEstimator: Sendable {
    func difficulty(of message: String, hasRepo: Bool) async -> TaskDifficulty
}

public struct WordDifficultyEstimator: DifficultyEstimator {
    public init() {}
    public func difficulty(of message: String, hasRepo: Bool) async -> TaskDifficulty {
        TaskDifficulty.estimate(message, hasRepo: hasRepo)
    }
}

/// What MAIPA-G knows about the user's OpenRouter money.
public struct AccountState: Codable, Sendable, Hashable {
    /// True when the account has never bought credit, so only the free AIs can answer.
    public var isFreeTier: Bool
    /// When a paid request was last refused for lack of credit.
    public var outOfCreditsAt: Date?

    public init(isFreeTier: Bool = false, outOfCreditsAt: Date? = nil) {
        self.isFreeTier = isFreeTier
        self.outOfCreditsAt = outOfCreditsAt
    }

    /// OpenRouter has no balance check for ordinary keys, so after a "no credit" refusal MAIPA-G
    /// sticks to free AIs for a while and then tries paid again, in case credit was added.
    public func paidAllowed(at now: Date = Date()) -> Bool {
        if isFreeTier { return false }
        guard let outOfCreditsAt else { return true }
        return now.timeIntervalSince(outOfCreditsAt) > 60 * 60
    }
}

/// The model settings for one request.
public struct Route: Sendable, Hashable {
    public var model: String
    public var plugins: [JSONValue]
    public var effort: ThinkingLevel?
    public var automaticCaching: Bool
    /// Only free AIs can answer this request.
    public var isFree: Bool
    /// Auto picked this route itself, so it may switch to free AIs when credit runs out.
    public var isAuto: Bool
    /// Words for the chat, such as "Auto · medium".
    public var label: String
    /// The most tokens the conversation may use in one request.
    public var contextBudget: Int
}

public enum ModelRouter {
    /// Picks the AI for one request.
    ///
    /// Auto follows Kiro's idea of Auto: cheaper AIs for easy things and stronger ones for hard work.
    /// It uses OpenRouter's own Auto router, which ranks models by what people actually use for
    /// each kind of task, and sets its cost band from how hard the request looks. With no credit,
    /// Auto and the free choice use OpenRouter's free-model router instead.
    public static func route(
        choice: ModelChoice,
        difficulty: TaskDifficulty,
        thinking: ThinkingLevel,
        account: AccountState,
        catalogue: [String: ModelInfo],
        requiresImageInput: Bool = false,
        now: Date = Date()
    ) -> Route {
        if requiresImageInput {
            switch choice {
            case .auto:
                let paid = account.paidAllowed(at: now)
                if let model = imageInputModel(in: catalogue, freeOnly: !paid) {
                    return route(choice: .model(model.id), difficulty: difficulty, thinking: thinking, account: account, catalogue: catalogue, requiresImageInput: false, now: now)
                }
            case .free:
                if let model = imageInputModel(in: catalogue, freeOnly: true) {
                    return route(choice: .model(model.id), difficulty: difficulty, thinking: thinking, account: account, catalogue: catalogue, requiresImageInput: false, now: now)
                }
            case .model:
                break
            }
        }
        switch choice {
        case .auto where account.paidAllowed(at: now):
            let routerLevels = catalogue[ModelChoice.autoID]?.thinkingLevels ?? [.low, .medium, .high]
            return Route(
                model: ModelChoice.autoID,
                plugins: [["id": "auto-router", "cost_tier": .string(difficulty.costTier)]],
                effort: thinking.nearest(in: routerLevels),
                automaticCaching: true,
                isFree: false,
                isAuto: true,
                label: "Auto · \(difficulty.costTier)",
                contextBudget: 150_000
            )
        case .auto:
            var route = freeRoute(thinking: thinking, catalogue: catalogue)
            route.isAuto = true
            route.label = "Auto · free AIs"
            return route
        case .free:
            return freeRoute(thinking: thinking, catalogue: catalogue)
        case .model(let id):
            let info = catalogue[id]
            let levels = info?.thinkingLevels ?? []
            let context = info?.contextLength ?? 128_000
            return Route(
                model: id,
                plugins: [],
                effort: levels.isEmpty ? nil : thinking.nearest(in: levels),
                automaticCaching: id.hasPrefix("anthropic/"),
                isFree: info?.isFree ?? id.hasSuffix(":free"),
                isAuto: false,
                label: info?.shortName ?? id,
                contextBudget: min(Int(Double(context) * 0.75), 300_000)
            )
        }
    }

    static func imageInputModel(in catalogue: [String: ModelInfo], freeOnly: Bool) -> ModelInfo? {
        catalogue.values.filter { $0.isChatModel && $0.acceptsImages && $0.supportsTools && (!freeOnly || $0.isFree) }
            .sorted {
                if $0.isFree != $1.isFree { return freeOnly ? $0.isFree : !$0.isFree }
                if ($0.created ?? .distantPast) != ($1.created ?? .distantPast) { return ($0.created ?? .distantPast) > ($1.created ?? .distantPast) }
                return $0.id < $1.id
            }.first
    }

    static func freeRoute(thinking: ThinkingLevel, catalogue: [String: ModelInfo]) -> Route {
        let levels = catalogue[ModelChoice.freeID]?.thinkingLevels ?? [.low, .medium, .high]
        return Route(
            model: ModelChoice.freeID,
            plugins: [],
            effort: thinking.nearest(in: levels),
            automaticCaching: false,
            isFree: true,
            isAuto: false,
            label: "Free AIs",
            // Free models vary; many hold 32,000 to 128,000 tokens.
            contextBudget: 60_000
        )
    }
}
