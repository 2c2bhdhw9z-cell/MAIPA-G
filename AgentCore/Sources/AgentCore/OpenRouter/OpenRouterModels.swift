import Foundation

/// How hard a model thinks before answering. OpenRouter's names, lowest to highest.
public enum ThinkingLevel: String, Codable, CaseIterable, Sendable, Comparable {
    case none, minimal, low, medium, high, xhigh, max

    public static let `default` = ThinkingLevel.medium

    private var rank: Int { Self.allCases.firstIndex(of: self) ?? 0 }
    public static func < (lhs: ThinkingLevel, rhs: ThinkingLevel) -> Bool { lhs.rank < rhs.rank }

    /// The closest level in `allowed`, preferring the lower one on a tie, so a model that lacks
    /// "medium" never silently gets the more expensive neighbour.
    public func nearest(in allowed: [ThinkingLevel]) -> ThinkingLevel? {
        guard !allowed.isEmpty else { return nil }
        if allowed.contains(self) { return self }
        return allowed.min { a, b in
            let da = abs(a.rank - rank), db = abs(b.rank - rank)
            return da == db ? a < b : da < db
        }
    }
}

/// What a model says about thinking in OpenRouter's catalogue.
public struct ReasoningCapability: Codable, Sendable, Hashable {
    public var mandatory: Bool
    /// nil means every level is accepted.
    public var supportedEfforts: [ThinkingLevel]?
    public var defaultEffort: ThinkingLevel?

    public init(mandatory: Bool, supportedEfforts: [ThinkingLevel]?, defaultEffort: ThinkingLevel?) {
        self.mandatory = mandatory
        self.supportedEfforts = supportedEfforts
        self.defaultEffort = defaultEffort
    }
}

/// One AI from OpenRouter's catalogue (GET /api/v1/models).
public struct ModelInfo: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var summary: String?
    public var contextLength: Int?
    /// US dollars per token. nil when the price is variable (the routers) or unknown.
    public var promptPrice: Double?
    public var completionPrice: Double?
    public var inputModalities: [String]
    public var outputModalities: [String]
    public var supportedParameters: Set<String>
    public var reasoning: ReasoningCapability?
    public var created: Date?

    public init(
        id: String,
        name: String,
        summary: String? = nil,
        contextLength: Int? = nil,
        promptPrice: Double? = nil,
        completionPrice: Double? = nil,
        inputModalities: [String] = ["text"],
        outputModalities: [String] = ["text"],
        supportedParameters: Set<String> = [],
        reasoning: ReasoningCapability? = nil,
        created: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.contextLength = contextLength
        self.promptPrice = promptPrice
        self.completionPrice = completionPrice
        self.inputModalities = inputModalities
        self.outputModalities = outputModalities
        self.supportedParameters = supportedParameters
        self.reasoning = reasoning
        self.created = created
    }

    public var isFree: Bool {
        id.hasSuffix(":free") || (promptPrice == 0 && completionPrice == 0)
    }

    public var isRouter: Bool { id.hasPrefix("openrouter/") }
    public var supportsTools: Bool { supportedParameters.contains("tools") }
    public var acceptsImages: Bool { inputModalities.contains("image") }
    public var acceptsFiles: Bool { inputModalities.contains("file") }
    public var generatesImages: Bool { outputModalities.contains("image") }

    /// The company, from "Anthropic: Claude Sonnet 5.5" or else from the id's prefix.
    public var maker: String {
        if let colon = name.firstIndex(of: ":") {
            return String(name[..<colon]).trimmingCharacters(in: .whitespaces)
        }
        let prefix = id.split(separator: "/").first.map(String.init) ?? id
        return prefix.prefix(1).uppercased() + prefix.dropFirst()
    }

    /// "Claude Sonnet 5.5" rather than "Anthropic: Claude Sonnet 5.5".
    public var shortName: String {
        if let colon = name.firstIndex(of: ":") {
            return String(name[name.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }
        return name
    }

    /// The thinking levels a picker should offer, highest last. Empty means "hide the control".
    public var thinkingLevels: [ThinkingLevel] {
        if let reasoning {
            var levels = reasoning.supportedEfforts ?? ThinkingLevel.allCases
            if reasoning.mandatory { levels.removeAll { $0 == .none } }
            return levels.sorted()
        }
        // The routers accept the setting and pass it to whichever model they pick. Only the
        // three levels every reasoning model understands are offered, and never "off", which a
        // model that must think would reject.
        if isRouter, supportedParameters.contains("reasoning") { return [.low, .medium, .high] }
        if supportedParameters.contains("reasoning") || supportedParameters.contains("reasoning_effort") {
            return [.low, .medium, .high]
        }
        return []
    }

    /// Whether this model can be used for a chat at all: it must write text, and the batch-only
    /// copies OpenRouter lists cannot answer a live chat.
    public var isChatModel: Bool {
        outputModalities.contains("text") && !id.hasSuffix(":batch")
    }

    /// Every non-batch OpenRouter model that can be searched and selected in the AI picker
    /// (including openrouter/* stealth/router models and multimodal/image-generating models).
    public var isSelectableModel: Bool {
        !id.hasSuffix(":batch")
    }
}

extension ModelInfo {
    /// Reads OpenRouter's catalogue JSON. Unknown or malformed entries are skipped, not fatal:
    /// the catalogue has hundreds of models and one odd entry must not hide the rest.
    public static func parseCatalogue(_ data: Data) throws -> [ModelInfo] {
        guard let root = JSONValue.parse(data), let items = root["data"]?.arrayValue else {
            throw HTTPError.undecodable(status: 200, type: "model list", detail: "no data array", body: String(decoding: data.prefix(300), as: UTF8.self))
        }
        return items.compactMap(ModelInfo.init(catalogueEntry:))
    }

    init?(catalogueEntry entry: JSONValue) {
        guard let id = entry["id"]?.stringValue else { return nil }
        let architecture = entry["architecture"]
        let pricing = entry["pricing"]
        func price(_ key: String) -> Double? {
            guard let value = pricing?[key]?.doubleValue, value >= 0 else { return nil }
            return value
        }
        var reasoning: ReasoningCapability?
        if let object = entry["reasoning"], !object.isNull {
            let efforts = object["supported_efforts"]?.arrayValue?.compactMap { $0.stringValue.flatMap(ThinkingLevel.init(rawValue:)) }
            reasoning = ReasoningCapability(
                mandatory: object["mandatory"]?.boolValue ?? false,
                supportedEfforts: efforts,
                defaultEffort: object["default_effort"]?.stringValue.flatMap(ThinkingLevel.init(rawValue:))
            )
        }
        let modalityString = architecture?["modality"]?.stringValue?.lowercased() ?? ""
        let modalityParts = modalityString.components(separatedBy: "->")
        let parsedInputs = architecture?["input_modalities"]?.arrayValue?.compactMap(\.stringValue).filter { !$0.isEmpty } ?? []
        let parsedOutputs = architecture?["output_modalities"]?.arrayValue?.compactMap(\.stringValue).filter { !$0.isEmpty } ?? []
        let fallbackInputs: [String] = {
            guard let lhs = modalityParts.first, !lhs.isEmpty else { return ["text"] }
            var list: [String] = []
            if lhs.contains("text") { list.append("text") }
            if lhs.contains("image") { list.append("image") }
            if lhs.contains("file") || lhs.contains("pdf") { list.append("file") }
            if lhs.contains("audio") { list.append("audio") }
            return list.isEmpty ? ["text"] : list
        }()
        let fallbackOutputs: [String] = {
            guard modalityParts.count > 1 else { return ["text"] }
            let rhs = modalityParts[1]
            var list: [String] = []
            if rhs.contains("text") { list.append("text") }
            if rhs.contains("image") { list.append("image") }
            if rhs.contains("audio") { list.append("audio") }
            return list.isEmpty ? ["text"] : list
        }()
        self.init(
            id: id,
            name: entry["name"]?.stringValue ?? id,
            summary: entry["description"]?.stringValue,
            contextLength: entry["context_length"]?.intValue ?? entry["top_provider"]?["context_length"]?.intValue,
            promptPrice: price("prompt"),
            completionPrice: price("completion"),
            inputModalities: parsedInputs.isEmpty ? fallbackInputs : parsedInputs,
            outputModalities: parsedOutputs.isEmpty ? fallbackOutputs : parsedOutputs,
            supportedParameters: Set(entry["supported_parameters"]?.arrayValue?.compactMap(\.stringValue) ?? []),
            reasoning: reasoning,
            created: entry["created"]?.doubleValue.map { Date(timeIntervalSince1970: $0) }
        )
    }
}

/// Account-wide OpenRouter credit totals (GET /api/v1/credits).
public struct OpenRouterCredits: Codable, Sendable, Hashable {
    public var purchased: Double
    public var used: Double
    public var balance: Double { max(0, purchased - used) }
    public init(purchased: Double, used: Double) { self.purchased = purchased; self.used = used }
    init(response: JSONValue) {
        let data = response["data"] ?? response
        purchased = data["total_credits"]?.doubleValue ?? data["purchased"]?.doubleValue ?? 0
        used = data["total_usage"]?.doubleValue ?? data["usage"]?.doubleValue ?? 0
    }
}

/// What OpenRouter says about the signed-in key (GET /api/v1/key).
public struct OpenRouterKeyInfo: Codable, Sendable, Hashable {
    public var label: String?
    /// Spending cap on this key in dollars, or nil for none.
    public var limit: Double?
    public var limitRemaining: Double?
    /// Dollars spent with this key, all time and today (UTC).
    public var usage: Double
    public var usageDaily: Double?
    /// True when the account has never bought credits.
    public var isFreeTier: Bool
    public var freeRequestsUsedToday: Int?
    public var freeRequestsLimitToday: Int?
    public var freeRequestsLeftToday: Int?

    public init(
        label: String? = nil,
        limit: Double? = nil,
        limitRemaining: Double? = nil,
        usage: Double = 0,
        usageDaily: Double? = nil,
        isFreeTier: Bool,
        freeRequestsUsedToday: Int? = nil,
        freeRequestsLimitToday: Int? = nil,
        freeRequestsLeftToday: Int? = nil
    ) {
        self.label = label
        self.limit = limit
        self.limitRemaining = limitRemaining
        self.usage = usage
        self.usageDaily = usageDaily
        self.isFreeTier = isFreeTier
        self.freeRequestsUsedToday = freeRequestsUsedToday
        self.freeRequestsLimitToday = freeRequestsLimitToday
        self.freeRequestsLeftToday = freeRequestsLeftToday
    }

    init(response: JSONValue) {
        let data = response["data"] ?? response
        let free = data["free_model_daily_requests"]
        self.init(
            label: data["label"]?.stringValue,
            limit: data["limit"]?.doubleValue,
            limitRemaining: data["limit_remaining"]?.doubleValue,
            usage: data["usage"]?.doubleValue ?? 0,
            usageDaily: data["usage_daily"]?.doubleValue,
            isFreeTier: data["is_free_tier"]?.boolValue ?? false,
            freeRequestsUsedToday: free?["used"]?.intValue,
            freeRequestsLimitToday: free?["limit"]?.intValue,
            freeRequestsLeftToday: free?["remaining"]?.intValue
        )
    }
}
