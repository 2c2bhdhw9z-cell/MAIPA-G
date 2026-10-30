import Foundation

// MARK: - Request

/// A message in OpenRouter's (OpenAI-compatible) chat format.
public struct APIMessage: Encodable, Sendable, Hashable {
    public enum Role: String, Codable, Sendable { case system, user, assistant, tool }

    public var role: Role
    public var content: String?
    /// OpenRouter multipart content for image/PDF input. nil keeps ordinary text messages unchanged.
    public var contentParts: [JSONValue]?
    public var toolCalls: [APIToolCall]?
    public var toolCallID: String?
    /// The model's own thinking blocks, returned exactly as received. Models such as Claude need
    /// them back while a tool-using answer is still in progress, or they lose their train of thought.
    public var reasoningDetails: [JSONValue]?

    public init(role: Role, content: String?, contentParts: [JSONValue]? = nil, toolCalls: [APIToolCall]? = nil, toolCallID: String? = nil, reasoningDetails: [JSONValue]? = nil) {
        self.role = role
        self.content = content
        self.contentParts = contentParts
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
        self.reasoningDetails = reasoningDetails
    }

    public static func system(_ text: String) -> APIMessage { APIMessage(role: .system, content: text) }
    public static func user(_ text: String) -> APIMessage { APIMessage(role: .user, content: text) }
    public static func tool(id: String, _ text: String) -> APIMessage { APIMessage(role: .tool, content: text, toolCallID: id) }

    enum CodingKeys: String, CodingKey {
        case role, content
        case toolCalls = "tool_calls"
        case toolCallID = "tool_call_id"
        case reasoningDetails = "reasoning_details"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(role, forKey: .role)
        if let contentParts, !contentParts.isEmpty {
            try container.encode(contentParts, forKey: .content)
        } else if let content {
            try container.encode(content, forKey: .content)
        } else {
            // An assistant turn that only called tools has no text. OpenAI's format says null.
            try container.encodeNil(forKey: .content)
        }
        if let toolCalls, !toolCalls.isEmpty { try container.encode(toolCalls, forKey: .toolCalls) }
        try container.encodeIfPresent(toolCallID, forKey: .toolCallID)
        if let reasoningDetails, !reasoningDetails.isEmpty { try container.encode(reasoningDetails, forKey: .reasoningDetails) }
    }
}

public struct APIToolCall: Codable, Sendable, Hashable {
    public struct Function: Codable, Sendable, Hashable {
        public var name: String
        /// JSON text, exactly as the model wrote it.
        public var arguments: String
        public init(name: String, arguments: String) {
            self.name = name
            self.arguments = arguments
        }
    }

    public var id: String
    public var type: String
    public var function: Function

    public init(id: String, name: String, arguments: String) {
        self.id = id
        self.type = "function"
        self.function = Function(name: name, arguments: arguments)
    }
}

/// A tool the model may call, described with a JSON Schema for its arguments.
public struct ToolSpec: Encodable, Sendable, Hashable {
    public struct Function: Codable, Sendable, Hashable {
        public var name: String
        public var description: String
        public var parameters: JSONValue
    }

    public var type: String
    public var function: Function
    public var serverOptions: JSONValue?

    public init(name: String, description: String, parameters: JSONValue) {
        self.type = "function"
        self.function = Function(name: name, description: description, parameters: parameters)
        self.serverOptions = nil
    }

    /// A tool OpenRouter runs itself, such as openrouter:web_search.
    public init(server name: String, options: JSONValue? = nil) {
        type = name
        function = Function(name: name, description: "", parameters: .object([:]))
        serverOptions = options
    }

    enum CodingKeys: String, CodingKey { case type, function, serverOptions = "options" }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)
        if type == "function" { try c.encode(function, forKey: .function) }
        try c.encodeIfPresent(serverOptions, forKey: .serverOptions)
    }
}

/// POST /api/v1/chat/completions, always streamed.
public struct ChatCompletionRequest: Encodable, Sendable {
    public var model: String
    /// Ordered fallbacks OpenRouter may use if the chosen provider fails or model disappears.
    public var models: [String]?
    public var messages: [APIMessage]
    public var tools: [ToolSpec]?
    public var reasoningEffort: ThinkingLevel?
    /// Router settings, such as `{"id": "auto-router", "cost_tier": "medium"}`.
    public var plugins: [JSONValue]?
    /// Keeps a conversation on one provider (and, for Auto, one model) so its prompt cache stays warm.
    public var sessionID: String?
    /// Turns on automatic prompt caching for the models that need asking (Anthropic's).
    public var automaticCaching: Bool
    public var maxTokens: Int?

    public init(
        model: String,
        models: [String]? = nil,
        messages: [APIMessage],
        tools: [ToolSpec]? = nil,
        reasoningEffort: ThinkingLevel? = nil,
        plugins: [JSONValue]? = nil,
        sessionID: String? = nil,
        automaticCaching: Bool = false,
        maxTokens: Int? = nil
    ) {
        self.model = model
        self.models = models
        self.messages = messages
        self.tools = tools
        self.reasoningEffort = reasoningEffort
        self.plugins = plugins
        self.sessionID = sessionID
        self.automaticCaching = automaticCaching
        self.maxTokens = maxTokens
    }

    enum CodingKeys: String, CodingKey {
        case model, models, messages, tools, stream, reasoning, plugins
        case toolChoice = "tool_choice"
        case sessionID = "session_id"
        case cacheControl = "cache_control"
        case maxTokens = "max_tokens"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(model, forKey: .model)
        try container.encodeIfPresent(models?.isEmpty == false ? models : nil, forKey: .models)
        try container.encode(messages, forKey: .messages)
        try container.encode(true, forKey: .stream)
        if let tools, !tools.isEmpty {
            try container.encode(tools, forKey: .tools)
            try container.encode("auto", forKey: .toolChoice)
        }
        if let reasoningEffort {
            let reasoning: JSONValue = ["effort": .string(reasoningEffort.rawValue)]
            try container.encode(reasoning, forKey: .reasoning)
        }
        if let plugins, !plugins.isEmpty { try container.encode(plugins, forKey: .plugins) }
        try container.encodeIfPresent(sessionID, forKey: .sessionID)
        if automaticCaching {
            let cache: JSONValue = ["type": "ephemeral"]
            try container.encode(cache, forKey: .cacheControl)
        }
        try container.encodeIfPresent(maxTokens, forKey: .maxTokens)
    }
}

// MARK: - Streamed response

/// Token counts and the price OpenRouter charged for one request.
public struct Usage: Codable, Sendable, Hashable {
    public var promptTokens: Int
    public var completionTokens: Int
    public var reasoningTokens: Int?
    public var cachedTokens: Int?
    public var cacheWriteTokens: Int?
    /// US dollars.
    public var cost: Double?

    public init(promptTokens: Int = 0, completionTokens: Int = 0, reasoningTokens: Int? = nil, cachedTokens: Int? = nil, cacheWriteTokens: Int? = nil, cost: Double? = nil) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.reasoningTokens = reasoningTokens
        self.cachedTokens = cachedTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.cost = cost
    }

    init(json: JSONValue) {
        self.init(
            promptTokens: json["prompt_tokens"]?.intValue ?? 0,
            completionTokens: json["completion_tokens"]?.intValue ?? 0,
            reasoningTokens: json["completion_tokens_details"]?["reasoning_tokens"]?.intValue,
            cachedTokens: json["prompt_tokens_details"]?["cached_tokens"]?.intValue,
            cacheWriteTokens: json["prompt_tokens_details"]?["cache_write_tokens"]?.intValue,
            cost: json["cost"]?.doubleValue
        )
    }

    public static func + (lhs: Usage, rhs: Usage) -> Usage {
        func sum(_ a: Int?, _ b: Int?) -> Int? { (a == nil && b == nil) ? nil : (a ?? 0) + (b ?? 0) }
        func sum(_ a: Double?, _ b: Double?) -> Double? { (a == nil && b == nil) ? nil : (a ?? 0) + (b ?? 0) }
        return Usage(
            promptTokens: lhs.promptTokens + rhs.promptTokens,
            completionTokens: lhs.completionTokens + rhs.completionTokens,
            reasoningTokens: sum(lhs.reasoningTokens, rhs.reasoningTokens),
            cachedTokens: sum(lhs.cachedTokens, rhs.cachedTokens),
            cacheWriteTokens: sum(lhs.cacheWriteTokens, rhs.cacheWriteTokens),
            cost: sum(lhs.cost, rhs.cost)
        )
    }
}

/// One `data:` event of a streamed reply, kept loose because providers differ in what they fill in.
public struct StreamChunk: Sendable {
    public var id: String?
    public var model: String?
    public var provider: String?
    public var contentDelta: String?
    public var reasoningDelta: String?
    public var reasoningDetails: [JSONValue]
    public var toolCallDeltas: [ToolCallDelta]
    public var finishReason: String?
    public var usage: Usage?
    public var error: OpenRouterAPIError?
    public var citations: [SourceCitation]

    public struct ToolCallDelta: Sendable, Hashable {
        public var index: Int?
        public var id: String?
        public var name: String?
        public var arguments: String?
    }

    public init(json: JSONValue) {
        id = json["id"]?.stringValue
        model = json["model"]?.stringValue
        provider = json["provider"]?.stringValue
        let choice = json["choices"]?.arrayValue?.first
        let delta = choice?["delta"] ?? choice?["message"]
        contentDelta = delta?["content"]?.stringValue
        reasoningDelta = delta?["reasoning"]?.stringValue ?? delta?["reasoning_content"]?.stringValue
        reasoningDetails = delta?["reasoning_details"]?.arrayValue ?? []
        toolCallDeltas = (delta?["tool_calls"]?.arrayValue ?? []).map { call in
            ToolCallDelta(
                index: call["index"]?.intValue,
                id: call["id"]?.stringValue,
                name: call["function"]?["name"]?.stringValue,
                arguments: call["function"]?["arguments"]?.stringValue
            )
        }
        finishReason = choice?["finish_reason"]?.stringValue
        usage = json["usage"].flatMap { $0.isNull ? nil : Usage(json: $0) }
        error = json["error"].flatMap { $0.isNull ? nil : OpenRouterAPIError(errorObject: $0, httpStatus: 200, retryAfter: nil) }
        citations = (delta?["annotations"]?.arrayValue ?? json["citations"]?.arrayValue ?? []).compactMap { annotation in
            let citation = annotation["url_citation"] ?? annotation
            guard let url = citation["url"]?.stringValue else { return nil }
            return SourceCitation(url: url, title: citation["title"]?.stringValue)
        }
    }
}

/// Builds one model reply out of its streamed pieces.
public struct StreamAccumulator: Sendable {
    public private(set) var text = ""
    public private(set) var reasoning = ""
    public private(set) var model: String?
    public private(set) var provider: String?
    public private(set) var generationID: String?
    public private(set) var finishReason: String?
    public private(set) var usage: Usage?
    public private(set) var error: OpenRouterAPIError?
    public private(set) var citations: [SourceCitation] = []

    private var detailOrder: [Int] = []
    private var details: [Int: [String: JSONValue]] = [:]
    private var callOrder: [Int] = []
    private var calls: [Int: (id: String?, name: String, arguments: String)] = [:]

    public init() {}

    public mutating func apply(_ chunk: StreamChunk) {
        if let id = chunk.id { generationID = id }
        if let model = chunk.model, !model.isEmpty { self.model = model }
        if let provider = chunk.provider, !provider.isEmpty { self.provider = provider }
        if let content = chunk.contentDelta { text += content }
        if let reasoningDelta = chunk.reasoningDelta { reasoning += reasoningDelta }
        for detail in chunk.reasoningDetails { mergeDetail(detail) }
        for delta in chunk.toolCallDeltas { mergeToolCall(delta) }
        if let finish = chunk.finishReason { finishReason = finish }
        if let usage = chunk.usage { self.usage = usage }
        if let error = chunk.error { self.error = error }
        for citation in chunk.citations where !citations.contains(where: { $0.url == citation.url }) { citations.append(citation) }
    }

    /// Reasoning blocks arrive in pieces that share an `index`. Text-like fields are joined;
    /// everything else (type, id, format) takes the latest value.
    private mutating func mergeDetail(_ detail: JSONValue) {
        guard let object = detail.objectValue else { return }
        let index: Int
        if let explicit = object["index"]?.intValue {
            index = explicit
        } else if let last = detailOrder.last, object["type"] == nil || details[last]?["type"] == object["type"] {
            index = last // a piece with no index continues the block before it
        } else {
            index = (detailOrder.max() ?? -1) + 1
        }
        if details[index] == nil {
            detailOrder.append(index)
            details[index] = [:]
        }
        for (key, value) in object {
            let joinable: Set<String> = ["text", "summary", "data", "signature"]
            if joinable.contains(key), case .string(let piece) = value {
                if case .string(let existing)? = details[index]?[key] {
                    details[index]?[key] = .string(existing + piece)
                } else {
                    details[index]?[key] = .string(piece)
                }
            } else if !value.isNull || details[index]?[key] == nil {
                details[index]?[key] = value
            }
        }
    }

    private mutating func mergeToolCall(_ delta: StreamChunk.ToolCallDelta) {
        let index: Int
        if let explicit = delta.index {
            index = explicit
        } else if let id = delta.id, !calls.values.contains(where: { $0.id == id }) {
            index = (callOrder.max() ?? -1) + 1
        } else {
            index = callOrder.last ?? 0
        }
        if calls[index] == nil {
            callOrder.append(index)
            calls[index] = (id: nil, name: "", arguments: "")
        }
        if let id = delta.id, !id.isEmpty { calls[index]?.id = id }
        if let name = delta.name { calls[index]?.name += name }
        if let arguments = delta.arguments { calls[index]?.arguments += arguments }
    }

    public var reasoningDetails: [JSONValue] {
        detailOrder.compactMap { details[$0].map(JSONValue.object) }
    }

    /// The finished tool calls. Calls the model left without an id get a stable made-up one, and
    /// empty argument text becomes "{}" so it can always be parsed.
    public var toolCalls: [APIToolCall] {
        callOrder.enumerated().compactMap { position, index in
            guard let call = calls[index], !call.name.isEmpty else { return nil }
            let id = call.id ?? "call_\(generationID ?? "local")_\(position)"
            let arguments = call.arguments.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "{}" : call.arguments
            return APIToolCall(id: id, name: call.name, arguments: arguments)
        }
    }

    public var hasOutput: Bool { !text.isEmpty || !toolCalls.isEmpty }
}
