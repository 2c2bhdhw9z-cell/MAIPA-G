import Foundation

// MARK: - Multi-Provider AI Gateway Presets & Configuration

/// Built-in first-class AI gateways supported alongside OpenRouter, plus custom OpenAI/Anthropic gateways.
public struct AIProviderPreset: Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var subtitle: String
    public var defaultBaseURL: String
    public var dashboardURL: String
    public var assetName: String
    public var keyPlaceholder: String

    public init(
        id: String,
        name: String,
        subtitle: String,
        defaultBaseURL: String,
        dashboardURL: String,
        assetName: String,
        keyPlaceholder: String
    ) {
        self.id = id
        self.name = name
        self.subtitle = subtitle
        self.defaultBaseURL = defaultBaseURL
        self.dashboardURL = dashboardURL
        self.assetName = assetName
        self.keyPlaceholder = keyPlaceholder
    }

    public static let builtIn: [AIProviderPreset] = [
        AIProviderPreset(
            id: "oneprovider",
            name: "OneProvider",
            subtitle: "Claude Fable/Opus/Sonnet, GPT-6.1, Gemini & DeepSeek on one key",
            defaultBaseURL: "https://api.oneprovider.dev/v1",
            dashboardURL: "https://app.oneprovider.dev",
            assetName: "ProviderOneProvider",
            keyPlaceholder: "sk-..."
        ),
        AIProviderPreset(
            id: "saygm",
            name: "SayGM",
            subtitle: "72 frontier & TEE enclave models across Claude, GPT, GLM, Kimi & Gemini",
            defaultBaseURL: "https://api.saygm.com/v1",
            dashboardURL: "https://saygm.com",
            assetName: "ProviderSayGM",
            keyPlaceholder: "SayGM API key"
        ),
        AIProviderPreset(
            id: "teamorouter",
            name: "TeamoRouter",
            subtitle: "Discounted official Claude, GPT-6, Gemini, DeepSeek, GLM & Grok router",
            defaultBaseURL: "https://api.teamorouter.com/v1",
            dashboardURL: "https://teamorouter.com",
            assetName: "ProviderTeamoRouter",
            keyPlaceholder: "sk-teamo-..."
        ),
        AIProviderPreset(
            id: "omniroute",
            name: "OmniRoute",
            subtitle: "Cheaper Inference cloud catalog or your own self-hosted OmniRoute gateway",
            defaultBaseURL: "https://api.cheaperinference.com/v1",
            dashboardURL: "https://www.omniroute.online",
            assetName: "ProviderOmniRoute",
            keyPlaceholder: "OmniRoute / Cheaper Inference API key"
        ),
    ]

    public static func matching(_ id: String) -> AIProviderPreset? {
        builtIn.first { $0.id == id }
    }
}

/// Non-secret metadata persisted in UserDefaults; `apiKey` is stored exclusively in Keychain on iPhone
/// (or passed through encrypted `MAIPAG_MCP_SECRETS` to ephemeral CloudRunner jobs).
public struct AIProviderEndpoint: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var baseURL: String
    public var apiKey: String
    public var isEnabled: Bool
    /// Optional per-model wire shape (`"messages"`, `"chat.completions"`, `"responses"`, `"generateContent"`, `"images.generations"`).
    public var modelWireHints: [String: String]

    public init(
        id: String,
        name: String,
        baseURL: String,
        apiKey: String = "",
        isEnabled: Bool = true,
        modelWireHints: [String: String] = [:]
    ) {
        self.id = id
        self.name = name
        self.baseURL = Self.normalizeBaseURL(baseURL)
        self.apiKey = apiKey
        self.isEnabled = isEnabled
        self.modelWireHints = modelWireHints
    }

    public var assetName: String? {
        AIProviderPreset.matching(id)?.assetName
    }

    public var isReady: Bool {
        isEnabled && !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && normalizedURL != nil
    }

    public var normalizedURL: URL? {
        URL(string: Self.normalizeBaseURL(baseURL))
    }

    public static func normalizeBaseURL(_ raw: String) -> String {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        if trimmed.isEmpty { return "" }
        if !trimmed.contains("://") {
            trimmed = "https://" + trimmed
        }
        // Ensure standard `/v1` suffix when a bare host like `https://api.oneprovider.dev` or `https://api.teamorouter.com` is entered.
        if let url = URL(string: trimmed), url.path.isEmpty || url.path == "/" {
            trimmed += "/v1"
        }
        return trimmed
    }

    /// Root URL without `/v1`, used for gateways that serve `/v1beta/models/...` or `/v1/messages`.
    public var rootURLString: String {
        let norm = Self.normalizeBaseURL(baseURL)
        if norm.hasSuffix("/v1") {
            return String(norm.dropLast(3))
        }
        return norm
    }
}

/// Encodes and decodes provider-scoped model IDs (`"oneprovider::claude-fable-5-1"`).
/// OpenRouter models keep their bare IDs (`"anthropic/claude-sonnet-4.5"`) for full compatibility.
public enum AIProviderModelID {
    public static let separator = "::"

    public static func encode(providerID: String, rawModelID: String) -> String {
        if providerID.isEmpty || providerID == "openrouter" { return rawModelID }
        return "\(providerID)\(separator)\(rawModelID)"
    }

    public static func decode(_ modelID: String) -> (providerID: String, rawModelID: String)? {
        guard let range = modelID.range(of: separator) else { return nil }
        let provider = String(modelID[..<range.lowerBound])
        let raw = String(modelID[range.upperBound...])
        guard !provider.isEmpty, !raw.isEmpty else { return nil }
        return (provider, raw)
    }

    public static func rawModelID(_ modelID: String) -> String {
        decode(modelID)?.rawModelID ?? modelID
    }

    public static func providerID(_ modelID: String) -> String {
        decode(modelID)?.providerID ?? "openrouter"
    }
}

// MARK: - Live Catalog Discovery & Normalization

public enum AIProviderGateway {
    public enum WireProtocol: String, Sendable {
        case openAIChatCompletions = "chat.completions"
        case anthropicMessages = "messages"
        case openAIResponses = "responses"
        case geminiGenerateContent = "generateContent"
    }

    /// Validates that a gateway URL is safe to contact (HTTPS required for internet hosts; HTTP allowed only for local/LAN self-hosted OmniRoute).
    public static func validateEndpointURL(_ url: URL) throws {
        guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased(), !host.isEmpty else {
            throw OpenRouterAPIError(httpStatus: 400, code: "invalid_url", message: "Enter a valid AI provider URL (such as https://api.oneprovider.dev/v1).")
        }
        if host == "169.254.169.254" || host == "metadata.google.internal" || host.hasPrefix("169.254.") {
            throw OpenRouterAPIError(httpStatus: 400, code: "blocked_host", message: "Cloud metadata addresses are blocked.")
        }
        if scheme == "https" { return }
        if scheme == "http" && (host == "localhost" || host == "127.0.0.1" || host.hasSuffix(".local") || host.hasPrefix("192.168.") || host.hasPrefix("10.")) {
            return
        }
        throw OpenRouterAPIError(httpStatus: 400, code: "https_required", message: "Use https:// for remote AI providers.")
    }

    /// Fetches the live model catalog from OneProvider, SayGM, TeamoRouter, OmniRoute, or any OpenAI-compatible gateway.
    public static func fetchModels(
        for endpoint: AIProviderEndpoint,
        transport: any HTTPTransport
    ) async throws -> (models: [ModelInfo], wireHints: [String: String]) {
        guard let base = endpoint.normalizedURL else {
            throw OpenRouterAPIError(httpStatus: 400, code: "invalid_url", message: "Invalid base URL for \(endpoint.name).")
        }
        try validateEndpointURL(base)

        let cleanKey = endpoint.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        var headers: [String: String] = ["Accept": "application/json"]
        if !cleanKey.isEmpty {
            headers["Authorization"] = "Bearer \(cleanKey)"
            headers["x-api-key"] = cleanKey
        }

        let modelsURL = base.appendingPathComponent("models")
        let response = try await transport.send(HTTPRequest(url: modelsURL, headers: headers, idleTimeout: 25))

        // TeamoRouter also serves rich pricing + context windows on `/v1/models/pricing`.
        var pricingItems: [String: JSONValue] = [:]
        if endpoint.id == "teamorouter" || base.host?.contains("teamorouter") == true {
            let pricingURL = base.appendingPathComponent("models/pricing")
            if let pricingResp = try? await transport.send(HTTPRequest(url: pricingURL, headers: ["Accept": "application/json"], idleTimeout: 20)),
               pricingResp.isSuccess,
               let root = JSONValue.parse(pricingResp.body),
               let arr = root["models"]?.arrayValue ?? root["data"]?.arrayValue {
                for entry in arr {
                    if let id = entry["id"]?.stringValue {
                        pricingItems[id] = entry
                    }
                }
            }
            if !response.isSuccess, !pricingItems.isEmpty {
                // If `/v1/models` failed (e.g. testing catalog before key), only throw if key was actually rejected (401/403).
                if response.status == 401 || response.status == 403 {
                    throw OpenRouterAPIError(status: response.status, body: response.body, headers: response.headers, providerName: endpoint.name)
                }
            }
        }

        guard response.isSuccess else {
            throw OpenRouterAPIError(status: response.status, body: response.body, headers: response.headers, providerName: endpoint.name)
        }

        var parsed = parseCatalogPayload(response.body, endpoint: endpoint, pricingOverlay: pricingItems)

        // Merge any TeamoRouter pricing models not already in `parsed`
        if !pricingItems.isEmpty {
            let seen = Set(parsed.models.map { AIProviderModelID.rawModelID($0.id) })
            for (rawID, entry) in pricingItems where !seen.contains(rawID) {
                if let built = buildModel(from: entry, rawID: rawID, endpoint: endpoint, overlay: nil) {
                    parsed.models.append(built.model)
                    if let hint = built.wireHint { parsed.wireHints[rawID] = hint }
                }
            }
        }

        // OmniRoute supports smart `auto` routing out of the box.
        if endpoint.id == "omniroute" || base.host?.contains("omniroute") == true || base.host?.contains("cheaperinference") == true {
            let autoID = AIProviderModelID.encode(providerID: endpoint.id, rawModelID: "auto")
            if !parsed.models.contains(where: { $0.id == autoID }) {
                parsed.models.insert(
                    ModelInfo(
                        id: autoID,
                        name: "\(endpoint.name): Auto Smart Router",
                        summary: "Routes automatically across your best healthy models on \(endpoint.name).",
                        contextLength: 200_000,
                        inputModalities: ["text", "image"],
                        outputModalities: ["text"],
                        supportedParameters: ["tools", "reasoning"],
                        reasoning: ReasoningCapability(mandatory: false, supportedEfforts: [.low, .medium, .high], defaultEffort: .medium)
                    ),
                    at: 0
                )
            }
        }

        return parsed
    }

    public static func parseCatalogPayload(
        _ data: Data,
        endpoint: AIProviderEndpoint,
        pricingOverlay: [String: JSONValue] = [:]
    ) -> (models: [ModelInfo], wireHints: [String: String]) {
        guard let root = JSONValue.parse(data) else { return ([], [:]) }
        let items: [JSONValue]
        if let arr = root["data"]?.arrayValue {
            items = arr
        } else if let arr = root["models"]?.arrayValue {
            items = arr
        } else if let arr = root.arrayValue {
            items = arr
        } else {
            return ([], [:])
        }

        var result: [ModelInfo] = []
        var hints: [String: String] = [:]
        var seen: Set<String> = []

        for entry in items {
            guard let rawID = entry["id"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !rawID.isEmpty,
                  !seen.contains(rawID) else { continue }
            if entry["coming_soon"]?.boolValue == true || entry["available"]?.boolValue == false {
                continue
            }
            seen.insert(rawID)
            if let built = buildModel(from: entry, rawID: rawID, endpoint: endpoint, overlay: pricingOverlay[rawID]) {
                result.append(built.model)
                if let hint = built.wireHint {
                    hints[rawID] = hint
                }
            }
        }
        return (result, hints)
    }

    private static func buildModel(
        from entry: JSONValue,
        rawID: String,
        endpoint: AIProviderEndpoint,
        overlay: JSONValue?
    ) -> (model: ModelInfo, wireHint: String?)? {
        let lower = rawID.lowercased()
        // Skip pure embedding/rerank/moderation/whisper models that aren't chat or image models
        if lower.contains("embed") || lower.contains("rerank") || lower.contains("moderation") || lower.contains("whisper") || lower.contains("tts") {
            return nil
        }

        let displayBase = entry["display_name"]?.stringValue
            ?? overlay?["display_name"]?.stringValue
            ?? entry["name"]?.stringValue
            ?? prettifyModelSlug(rawID)
        let cleanTitle = displayBase.contains(":") ? displayBase : "\(endpoint.name): \(displayBase)"

        let contextLen = entry["context_length"]?.intValue
            ?? entry["context_window"]?.intValue
            ?? overlay?["context_window"]?.intValue
            ?? entry["max_context_tokens"]?.intValue
            ?? inferredContextLength(for: lower)

        // Pricing normalization to USD per single token:
        // 1. OpenRouter style: `pricing.prompt` / `pricing.completion` (already USD/token when < 0.05, or USD/1M if > 0.05)
        // 2. SayGM style: `pricing.dimensions.input_per_mtok_ndollars` (nano-dollars per 1M tokens -> divide by 1e15!)
        // 3. TeamoRouter / OmniRoute style: `cost.input` / `cost.output` or `input_price` (USD per 1M tokens -> divide by 1e6!)
        let (promptPrice, completionPrice) = extractPerTokenPrices(entry: entry, overlay: overlay, rawID: lower)

        // Wire shape detection (`api_shapes` on SayGM, or model family on TeamoRouter)
        let shapes = (entry["api_shapes"]?.arrayValue ?? []).compactMap(\.stringValue)
        var wireHint: String?
        if shapes.contains("chat.completions") {
            wireHint = WireProtocol.openAIChatCompletions.rawValue
        } else if shapes.contains("messages") {
            wireHint = WireProtocol.anthropicMessages.rawValue
        } else if shapes.contains("responses") {
            wireHint = WireProtocol.openAIResponses.rawValue
        } else if shapes.contains("streamGenerateContent") || shapes.contains("generateContent") {
            wireHint = WireProtocol.geminiGenerateContent.rawValue
        } else if shapes.contains("images.generations") {
            wireHint = "images.generations"
        } else if (endpoint.id == "teamorouter" || endpoint.id == "saygm") && lower.hasPrefix("claude") {
            wireHint = WireProtocol.anthropicMessages.rawValue
        }

        // Capabilities & Modalities
        let caps = entry["capabilities"]
        let arch = entry["architecture"]
        var inputMods = (arch?["input_modalities"]?.arrayValue?.compactMap(\.stringValue)) ?? []
        var outputMods = (arch?["output_modalities"]?.arrayValue?.compactMap(\.stringValue)) ?? []

        let isImageGen = caps?["image_generation"]?.boolValue == true
            || caps?["image_output"]?.boolValue == true
            || shapes.contains("images.generations")
            || lower.contains("flux") || lower.contains("imagen") || lower.contains("gpt-image") || lower.contains("ideogram") || lower.contains("grok-imagine")

        if outputMods.isEmpty {
            outputMods = isImageGen && !shapes.contains("chat.completions") ? ["image"] : ["text"]
        }
        if inputMods.isEmpty {
            let hasVision = caps?["vision"]?.boolValue == true
                || caps?["image_input"]?.boolValue == true
                || lower.contains("claude") || lower.contains("gpt-4") || lower.contains("gpt-5") || lower.contains("gpt-6")
                || lower.contains("gemini") || lower.contains("vl") || lower.contains("vision") || lower.contains("grok-4") || lower.contains("kimi-k2")
            inputMods = hasVision ? ["text", "image"] : ["text"]
        }

        var params = Set((entry["supported_parameters"]?.arrayValue ?? []).compactMap(\.stringValue))
        let supportsTools = caps?["tools"]?.boolValue ?? (!isImageGen)
        if supportsTools { params.insert("tools") }

        let supportsReasoning = params.contains("reasoning")
            || caps?["reasoning"]?.boolValue == true
            || lower.contains("claude-opus") || lower.contains("claude-sonnet") || lower.contains("claude-fable")
            || lower.contains("gpt-5") || lower.contains("gpt-6") || lower.contains("o1") || lower.contains("o3") || lower.contains("o4")
            || lower.contains("reasoner") || lower.contains("-r1") || lower.contains("thinking") || lower.contains("qwq")
            || lower.contains("deepseek-v4") || lower.contains("glm-5") || lower.contains("gemini-2.5") || lower.contains("gemini-3") || lower.contains("gemini-4") || lower.contains("grok")

        var reasoning: ReasoningCapability?
        if supportsReasoning {
            params.insert("reasoning")
            reasoning = ReasoningCapability(mandatory: false, supportedEfforts: [.low, .medium, .high], defaultEffort: .medium)
        }

        let createdDate: Date? = {
            if let ts = entry["created"]?.doubleValue, ts > 1_000_000_000 {
                return Date(timeIntervalSince1970: ts > 10_000_000_000 ? ts / 1000.0 : ts)
            }
            if let sortOrder = (entry["sort_order"]?.doubleValue ?? overlay?["sort_order"]?.doubleValue), sortOrder > 1_000_000_000_000 {
                return Date(timeIntervalSince1970: sortOrder / 1000.0)
            }
            return nil
        }()

        let summaryParts: [String] = [
            "Served via \(endpoint.name)",
            entry["owned_by"]?.stringValue.map { "Maker: \($0)" },
            entry["confidential"]?.boolValue == true ? "Confidential TEE enclave" : nil,
        ].compactMap { $0 }

        let model = ModelInfo(
            id: AIProviderModelID.encode(providerID: endpoint.id, rawModelID: rawID),
            name: cleanTitle,
            summary: summaryParts.joined(separator: " · "),
            contextLength: contextLen,
            promptPrice: promptPrice,
            completionPrice: completionPrice,
            inputModalities: inputMods,
            outputModalities: outputMods,
            supportedParameters: params,
            reasoning: reasoning,
            created: createdDate
        )
        return (model, wireHint)
    }

    private static func extractPerTokenPrices(entry: JSONValue, overlay: JSONValue?, rawID: String) -> (Double?, Double?) {
        if rawID.hasSuffix("-free") || rawID.hasSuffix(":free") {
            return (0, 0)
        }
        // SayGM nano-dollars per 1M tokens
        if let dims = entry["pricing"]?["dimensions"],
           let inNano = dims["input_per_mtok_ndollars"]?.doubleValue,
           let outNano = dims["output_per_mtok_ndollars"]?.doubleValue {
            return (inNano / 1_000_000_000_000_000.0, outNano / 1_000_000_000_000_000.0)
        }
        // OpenRouter-style pricing.prompt / pricing.completion
        if let p = numberFromJSON(entry["pricing"]?["prompt"]),
           let c = numberFromJSON(entry["pricing"]?["completion"]) {
            // If reported per-million (> 0.01 USD), divide by 1M; if already per-token (< 0.01), keep as-is
            let scale = (p > 0.01 || c > 0.01) ? 1_000_000.0 : 1.0
            return (p / scale, c / scale)
        }
        // TeamoRouter / OmniRoute cost.input & cost.output (USD per 1M tokens)
        let costObj = entry["cost"] ?? overlay?["cost"]
        if let inM = numberFromJSON(costObj?["input"]) ?? numberFromJSON(entry["input_price"]),
           let outM = numberFromJSON(costObj?["output"]) ?? numberFromJSON(entry["output_price"]) {
            return (inM / 1_000_000.0, outM / 1_000_000.0)
        }
        return (nil, nil)
    }

    private static func numberFromJSON(_ value: JSONValue?) -> Double? {
        if let d = value?.doubleValue { return d }
        if let s = value?.stringValue, let d = Double(s) { return d }
        return nil
    }

    private static func inferredContextLength(for lowerID: String) -> Int {
        if lowerID.contains("claude-fable") || lowerID.contains("claude-opus-5") || lowerID.contains("claude-sonnet-5") || lowerID.contains("gemini") || lowerID.contains("gpt-6") || lowerID.contains("gpt-5.6") {
            return 1_000_000
        }
        if lowerID.contains("claude") || lowerID.contains("gpt-5") || lowerID.contains("kimi") || lowerID.contains("glm") || lowerID.contains("grok") {
            return 200_000
        }
        return 128_000
    }

    private static func prettifyModelSlug(_ raw: String) -> String {
        let base = raw.split(separator: "/").last.map(String.init) ?? raw
        let upperSet: Set<String> = ["gpt", "glm", "vl", "oss", "tee", "ai", "qwq"]
        return base.split(separator: "-").map { part in
            let low = part.lowercased()
            if upperSet.contains(low) { return low.uppercased() }
            return part.prefix(1).uppercased() + part.dropFirst()
        }.joined(separator: " ")
    }

    // MARK: - Streaming Chat Across OpenAI, Anthropic, Responses, & Gemini Wire Protocols

    public static func resolveWireProtocol(for rawModelID: String, endpoint: AIProviderEndpoint) -> WireProtocol {
        if let hint = endpoint.modelWireHints[rawModelID], let proto = WireProtocol(rawValue: hint) {
            return proto
        }
        let lower = rawModelID.lowercased()
        if (endpoint.id == "saygm" || endpoint.id == "teamorouter"), lower.hasPrefix("claude") {
            return .anthropicMessages
        }
        if endpoint.id == "saygm", lower.hasPrefix("gemini") {
            return .geminiGenerateContent
        }
        return .openAIChatCompletions
    }

    public static func stream(
        _ request: ChatCompletionRequest,
        rawModelID: String,
        endpoint: AIProviderEndpoint,
        transport: any HTTPTransport
    ) async throws -> AsyncThrowingStream<StreamChunk, Error> {
        guard let base = endpoint.normalizedURL else {
            throw OpenRouterAPIError(httpStatus: 400, code: "invalid_url", message: "Invalid base URL for \(endpoint.name).")
        }
        try validateEndpointURL(base)
        let proto = resolveWireProtocol(for: rawModelID, endpoint: endpoint)
        switch proto {
        case .anthropicMessages:
            return try await streamAnthropicMessages(request, rawModelID: rawModelID, endpoint: endpoint, transport: transport)
        case .geminiGenerateContent:
            return try await streamGeminiGenerateContent(request, rawModelID: rawModelID, endpoint: endpoint, transport: transport)
        case .openAIResponses:
            return try await streamOpenAIResponses(request, rawModelID: rawModelID, endpoint: endpoint, base: base, transport: transport)
        case .openAIChatCompletions:
            return try await streamOpenAIChatCompletions(request, rawModelID: rawModelID, endpoint: endpoint, base: base, transport: transport)
        }
    }

    // 1. Standard OpenAI `/v1/chat/completions`
    private static func streamOpenAIChatCompletions(
        _ request: ChatCompletionRequest,
        rawModelID: String,
        endpoint: AIProviderEndpoint,
        base: URL,
        transport: any HTTPTransport
    ) async throws -> AsyncThrowingStream<StreamChunk, Error> {
        let cleanKey = endpoint.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        var headers = [
            "Accept": "text/event-stream",
            "Content-Type": "application/json",
        ]
        if !cleanKey.isEmpty {
            headers["Authorization"] = "Bearer \(cleanKey)"
        }

        let functionTools = (request.tools ?? []).filter { $0.type == "function" }
        var bodyObj: [String: JSONValue] = [
            "model": .string(rawModelID),
            "stream": .bool(true),
            "stream_options": ["include_usage": .bool(true)],
            "messages": .array(request.messages.map(encodeOpenAIMessage)),
        ]
        if !functionTools.isEmpty {
            bodyObj["tools"] = .array(functionTools.map { spec in
                [
                    "type": "function",
                    "function": [
                        "name": .string(spec.function.name),
                        "description": .string(spec.function.description),
                        "parameters": spec.function.parameters,
                    ],
                ]
            })
        }
        if let maxTokens = request.maxTokens {
            bodyObj["max_tokens"] = .number(Double(maxTokens))
        }
        if let effort = request.reasoningEffort, effort != .none {
            let mapped: String = switch effort {
            case .none, .minimal, .low: "low"
            case .medium: "medium"
            case .high, .xhigh, .max: "high"
            }
            bodyObj["reasoning_effort"] = .string(mapped)
        }

        let url = base.appendingPathComponent("chat/completions")
        let http = try HTTPRequest.json("POST", url, body: JSONValue.object(bodyObj), headers: headers, idleTimeout: 180)
        let response = try await transport.stream(http)
        guard response.isSuccess else {
            let errBody = try await response.collect(limit: 64 * 1024)
            throw OpenRouterAPIError(status: response.status, body: errBody, headers: response.headers, providerName: endpoint.name)
        }

        let contentType = response.headers["content-type"]?.lowercased() ?? ""
        if contentType.contains("application/json") && !contentType.contains("event-stream") {
            let fullBody = try await response.collect(limit: 4 * 1024 * 1024)
            return AsyncThrowingStream { continuation in
                if let json = JSONValue.parse(fullBody) {
                    var chunk = StreamChunk(json: json)
                    if chunk.provider == nil { chunk.provider = endpoint.name }
                    continuation.yield(chunk)
                }
                continuation.finish()
            }
        }

        let events = response.body.serverSentEvents()
        let providerName = endpoint.name
        return AsyncThrowingStream<StreamChunk, Error> { continuation in
            let task = Task {
                do {
                    for try await event in events {
                        if event == "[DONE]" { break }
                        guard let json = JSONValue.parse(event) else { continue }
                        var chunk = StreamChunk(json: json)
                        if chunk.provider == nil { chunk.provider = providerName }
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func encodeOpenAIMessage(_ msg: APIMessage) -> JSONValue {
        var obj: [String: JSONValue] = ["role": .string(msg.role.rawValue)]
        if let parts = msg.contentParts, !parts.isEmpty {
            // Convert OpenRouter PDF `file` parts to readable note if an OpenAI-only gateway doesn't understand `file_data`
            let sanitized = parts.map { part -> JSONValue in
                if part["type"]?.stringValue == "file" {
                    let name = part["file"]?["filename"]?.stringValue ?? "document.pdf"
                    return ["type": "text", "text": .string("[Attached PDF: \(name)]")]
                }
                return part
            }
            obj["content"] = .array(sanitized)
        } else if let content = msg.content {
            obj["content"] = .string(content)
        } else {
            obj["content"] = .null
        }
        if let calls = msg.toolCalls, !calls.isEmpty {
            obj["tool_calls"] = .array(calls.map { call in
                [
                    "id": .string(call.id),
                    "type": "function",
                    "function": [
                        "name": .string(call.function.name),
                        "arguments": .string(call.function.arguments),
                    ],
                ]
            })
        }
        if let id = msg.toolCallID {
            obj["tool_call_id"] = .string(id)
        }
        return .object(obj)
    }

    // 2. Native Anthropic `/v1/messages` (for Claude models on SayGM, TeamoRouter, OneProvider, or Anthropic-compatible URLs)
    private static func streamAnthropicMessages(
        _ request: ChatCompletionRequest,
        rawModelID: String,
        endpoint: AIProviderEndpoint,
        transport: any HTTPTransport
    ) async throws -> AsyncThrowingStream<StreamChunk, Error> {
        let cleanKey = endpoint.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        var headers = [
            "Accept": "text/event-stream",
            "Content-Type": "application/json",
            "anthropic-version": "2023-06-01",
        ]
        if !cleanKey.isEmpty {
            headers["x-api-key"] = cleanKey
            headers["Authorization"] = "Bearer \(cleanKey)"
        }

        var systemTexts: [String] = []
        var anthropicMessages: [[String: JSONValue]] = []

        func appendAnthropicMessage(role: String, blocks: [JSONValue]) {
            guard !blocks.isEmpty else { return }
            if let lastIdx = anthropicMessages.indices.last, anthropicMessages[lastIdx]["role"]?.stringValue == role,
               let existing = anthropicMessages[lastIdx]["content"]?.arrayValue {
                anthropicMessages[lastIdx]["content"] = .array(existing + blocks)
            } else {
                anthropicMessages.append(["role": .string(role), "content": .array(blocks)])
            }
        }

        for msg in request.messages {
            switch msg.role {
            case .system:
                if let text = msg.content, !text.isEmpty { systemTexts.append(text) }
            case .user:
                var blocks: [JSONValue] = []
                if let parts = msg.contentParts, !parts.isEmpty {
                    for part in parts {
                        if part["type"]?.stringValue == "text", let text = part["text"]?.stringValue, !text.isEmpty {
                            blocks.append(["type": "text", "text": .string(text)])
                        } else if part["type"]?.stringValue == "image_url",
                                  let dataURL = part["image_url"]?["url"]?.stringValue,
                                  let (mime, b64) = splitDataURL(dataURL) {
                            blocks.append([
                                "type": "image",
                                "source": [
                                    "type": "base64",
                                    "media_type": .string(mime),
                                    "data": .string(b64),
                                ],
                            ])
                        } else if part["type"]?.stringValue == "file",
                                  let fileData = part["file"]?["file_data"]?.stringValue,
                                  let (mime, b64) = splitDataURL(fileData), mime == "application/pdf" {
                            blocks.append([
                                "type": "document",
                                "source": [
                                    "type": "base64",
                                    "media_type": "application/pdf",
                                    "data": .string(b64),
                                ],
                            ])
                        }
                    }
                } else if let text = msg.content, !text.isEmpty {
                    blocks.append(["type": "text", "text": .string(text)])
                }
                if blocks.isEmpty {
                    blocks.append(["type": "text", "text": "Continue."])
                }
                appendAnthropicMessage(role: "user", blocks: blocks)

            case .assistant:
                var blocks: [JSONValue] = []
                if let text = msg.content, !text.isEmpty {
                    blocks.append(["type": "text", "text": .string(text)])
                }
                for call in msg.toolCalls ?? [] {
                    let parsedInput = JSONValue.parse(call.function.arguments) ?? .object([:])
                    let inputObj: JSONValue = parsedInput.objectValue != nil ? parsedInput : .object([:])
                    blocks.append([
                        "type": "tool_use",
                        "id": .string(call.id),
                        "name": .string(call.function.name),
                        "input": inputObj,
                    ])
                }
                appendAnthropicMessage(role: "assistant", blocks: blocks)

            case .tool:
                let toolID = msg.toolCallID ?? "tool_call"
                let resultBlock: JSONValue = [
                    "type": "tool_result",
                    "tool_use_id": .string(toolID),
                    "content": .string(msg.content ?? ""),
                ]
                appendAnthropicMessage(role: "user", blocks: [resultBlock])
            }
        }

        if anthropicMessages.isEmpty {
            anthropicMessages.append(["role": "user", "content": .array([["type": "text", "text": "Hello"]])])
        }

        var maxTokens = request.maxTokens ?? 8_192
        var bodyObj: [String: JSONValue] = [
            "model": .string(rawModelID),
            "stream": .bool(true),
            "messages": .array(anthropicMessages.map(JSONValue.object)),
        ]
        if !systemTexts.isEmpty {
            bodyObj["system"] = .string(systemTexts.joined(separator: "\n\n"))
        }

        let functionTools = (request.tools ?? []).filter { $0.type == "function" }
        if !functionTools.isEmpty {
            bodyObj["tools"] = .array(functionTools.map { spec in
                [
                    "name": .string(spec.function.name),
                    "description": .string(spec.function.description),
                    "input_schema": spec.function.parameters,
                ]
            })
        }

        if let effort = request.reasoningEffort, effort != .none, !rawModelID.lowercased().contains("haiku-3") {
            let budget: Int = switch effort {
            case .none, .minimal: 1_024
            case .low: 2_048
            case .medium: 4_096
            case .high: 8_192
            case .xhigh, .max: 16_000
            }
            maxTokens = max(maxTokens, budget + 4_096)
            bodyObj["thinking"] = [
                "type": "enabled",
                "budget_tokens": .number(Double(budget)),
            ]
        }
        bodyObj["max_tokens"] = .number(Double(maxTokens))

        guard let messagesURL = URL(string: endpoint.rootURLString + "/v1/messages") else {
            throw OpenRouterAPIError(httpStatus: 400, code: "invalid_url", message: "Invalid Anthropic messages URL for \(endpoint.name).")
        }
        let http = try HTTPRequest.json("POST", messagesURL, body: JSONValue.object(bodyObj), headers: headers, idleTimeout: 180)
        let response = try await transport.stream(http)
        guard response.isSuccess else {
            let errBody = try await response.collect(limit: 64 * 1024)
            throw OpenRouterAPIError(status: response.status, body: errBody, headers: response.headers, providerName: endpoint.name)
        }

        let events = response.body.serverSentEvents()
        let providerName = endpoint.name
        return AsyncThrowingStream<StreamChunk, Error> { continuation in
            let task = Task {
                var inputTokens = 0
                var outputTokens = 0
                var msgID: String?
                var modelSeen: String? = rawModelID
                var blockToToolIndex: [Int: Int] = [:]
                var nextToolIndex = 0
                do {
                    for try await event in events {
                        if event == "[DONE]" { break }
                        guard let json = JSONValue.parse(event) else { continue }
                        let type = json["type"]?.stringValue ?? ""
                        switch type {
                        case "message_start":
                            let m = json["message"]
                            msgID = m?["id"]?.stringValue ?? msgID
                            modelSeen = m?["model"]?.stringValue ?? modelSeen
                            if let inTok = m?["usage"]?["input_tokens"]?.intValue {
                                inputTokens = inTok
                            }
                        case "content_block_start":
                            let blockIdx = json["index"]?.intValue ?? 0
                            let cb = json["content_block"]
                            if cb?["type"]?.stringValue == "tool_use" {
                                let tIdx = nextToolIndex
                                nextToolIndex += 1
                                blockToToolIndex[blockIdx] = tIdx
                                let delta = StreamChunk.ToolCallDelta(
                                    index: tIdx,
                                    id: cb?["id"]?.stringValue,
                                    name: cb?["name"]?.stringValue,
                                    arguments: ""
                                )
                                continuation.yield(StreamChunk(id: msgID, model: modelSeen, provider: providerName, toolCallDeltas: [delta]))
                            }
                        case "content_block_delta":
                            let blockIdx = json["index"]?.intValue ?? 0
                            let delta = json["delta"]
                            let dType = delta?["type"]?.stringValue ?? ""
                            if dType == "text_delta", let text = delta?["text"]?.stringValue {
                                continuation.yield(StreamChunk(id: msgID, model: modelSeen, provider: providerName, contentDelta: text))
                            } else if dType == "thinking_delta", let thought = delta?["thinking"]?.stringValue {
                                continuation.yield(StreamChunk(id: msgID, model: modelSeen, provider: providerName, reasoningDelta: thought))
                            } else if dType == "input_json_delta", let partial = delta?["partial_json"]?.stringValue {
                                let tIdx = blockToToolIndex[blockIdx] ?? 0
                                let tc = StreamChunk.ToolCallDelta(index: tIdx, arguments: partial)
                                continuation.yield(StreamChunk(id: msgID, model: modelSeen, provider: providerName, toolCallDeltas: [tc]))
                            }
                        case "message_delta":
                            let stop = json["delta"]?["stop_reason"]?.stringValue
                            if let outTok = json["usage"]?["output_tokens"]?.intValue {
                                outputTokens = outTok
                            }
                            let finish: String? = switch stop {
                            case "max_tokens": "length"
                            case "tool_use": "tool_calls"
                            case .some: "stop"
                            case nil: nil
                            }
                            let usage = Usage(promptTokens: inputTokens, completionTokens: outputTokens)
                            continuation.yield(StreamChunk(id: msgID, model: modelSeen, provider: providerName, finishReason: finish, usage: usage))
                        case "error":
                            if let errObj = json["error"] {
                                let msg = errObj["message"]?.stringValue ?? "Provider error"
                                continuation.yield(StreamChunk(error: OpenRouterAPIError(httpStatus: 500, code: errObj["type"]?.stringValue ?? "error", message: "\(providerName): \(msg)")))
                            }
                        default:
                            break
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // 3. OpenAI `/v1/responses` (for Responses-only models like `gpt-5.5-pro` on SayGM)
    private static func streamOpenAIResponses(
        _ request: ChatCompletionRequest,
        rawModelID: String,
        endpoint: AIProviderEndpoint,
        base: URL,
        transport: any HTTPTransport
    ) async throws -> AsyncThrowingStream<StreamChunk, Error> {
        let cleanKey = endpoint.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        var headers = [
            "Accept": "text/event-stream",
            "Content-Type": "application/json",
        ]
        if !cleanKey.isEmpty { headers["Authorization"] = "Bearer \(cleanKey)" }

        var instructions: [String] = []
        var inputItems: [JSONValue] = []
        for msg in request.messages {
            switch msg.role {
            case .system:
                if let text = msg.content, !text.isEmpty { instructions.append(text) }
            case .user:
                if let parts = msg.contentParts, !parts.isEmpty {
                    let converted = parts.compactMap { p -> JSONValue? in
                        if p["type"]?.stringValue == "text", let t = p["text"]?.stringValue {
                            return ["type": "input_text", "text": .string(t)]
                        }
                        if p["type"]?.stringValue == "image_url", let u = p["image_url"]?["url"]?.stringValue {
                            return ["type": "input_image", "image_url": .string(u)]
                        }
                        return nil
                    }
                    inputItems.append(["role": "user", "content": .array(converted)])
                } else {
                    inputItems.append(["role": "user", "content": .string(msg.content ?? "")])
                }
            case .assistant:
                if let text = msg.content, !text.isEmpty {
                    inputItems.append(["role": "assistant", "content": .string(text)])
                }
                for call in msg.toolCalls ?? [] {
                    inputItems.append([
                        "type": "function_call",
                        "call_id": .string(call.id),
                        "name": .string(call.function.name),
                        "arguments": .string(call.function.arguments),
                    ])
                }
            case .tool:
                inputItems.append([
                    "type": "function_call_output",
                    "call_id": .string(msg.toolCallID ?? "call"),
                    "output": .string(msg.content ?? ""),
                ])
            }
        }

        var bodyObj: [String: JSONValue] = [
            "model": .string(rawModelID),
            "stream": .bool(true),
            "input": .array(inputItems),
        ]
        if !instructions.isEmpty {
            bodyObj["instructions"] = .string(instructions.joined(separator: "\n\n"))
        }
        let functionTools = (request.tools ?? []).filter { $0.type == "function" }
        if !functionTools.isEmpty {
            bodyObj["tools"] = .array(functionTools.map { spec in
                [
                    "type": "function",
                    "name": .string(spec.function.name),
                    "description": .string(spec.function.description),
                    "parameters": spec.function.parameters,
                ]
            })
        }

        let http = try HTTPRequest.json("POST", base.appendingPathComponent("responses"), body: JSONValue.object(bodyObj), headers: headers, idleTimeout: 180)
        let response = try await transport.stream(http)
        guard response.isSuccess else {
            let errBody = try await response.collect(limit: 64 * 1024)
            throw OpenRouterAPIError(status: response.status, body: errBody, headers: response.headers, providerName: endpoint.name)
        }

        let events = response.body.serverSentEvents()
        let providerName = endpoint.name
        return AsyncThrowingStream<StreamChunk, Error> { continuation in
            let task = Task {
                var itemToCallIndex: [String: Int] = [:]
                var nextIdx = 0
                do {
                    for try await event in events {
                        if event == "[DONE]" { break }
                        guard let json = JSONValue.parse(event) else { continue }
                        let type = json["type"]?.stringValue ?? ""
                        switch type {
                        case "response.output_text.delta":
                            if let d = json["delta"]?.stringValue {
                                continuation.yield(StreamChunk(model: rawModelID, provider: providerName, contentDelta: d))
                            }
                        case "response.reasoning_summary_text.delta":
                            if let d = json["delta"]?.stringValue {
                                continuation.yield(StreamChunk(model: rawModelID, provider: providerName, reasoningDelta: d))
                            }
                        case "response.output_item.added":
                            if let item = json["item"], item["type"]?.stringValue == "function_call" {
                                let itemID = item["id"]?.stringValue ?? UUID().uuidString
                                let idx = nextIdx; nextIdx += 1
                                itemToCallIndex[itemID] = idx
                                let tc = StreamChunk.ToolCallDelta(
                                    index: idx,
                                    id: item["call_id"]?.stringValue ?? itemID,
                                    name: item["name"]?.stringValue,
                                    arguments: ""
                                )
                                continuation.yield(StreamChunk(model: rawModelID, provider: providerName, toolCallDeltas: [tc]))
                            }
                        case "response.function_call_arguments.delta":
                            let itemID = json["item_id"]?.stringValue ?? ""
                            let idx = itemToCallIndex[itemID] ?? 0
                            if let d = json["delta"]?.stringValue {
                                continuation.yield(StreamChunk(model: rawModelID, provider: providerName, toolCallDeltas: [.init(index: idx, arguments: d)]))
                            }
                        case "response.completed":
                            let u = json["response"]?["usage"]
                            let inT = u?["input_tokens"]?.intValue ?? 0
                            let outT = u?["output_tokens"]?.intValue ?? 0
                            continuation.yield(StreamChunk(model: rawModelID, provider: providerName, finishReason: "stop", usage: Usage(promptTokens: inT, completionTokens: outT)))
                        default:
                            break
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // 4. Gemini `/v1beta/models/{model}:streamGenerateContent?alt=sse` (for SayGM native Gemini models)
    private static func streamGeminiGenerateContent(
        _ request: ChatCompletionRequest,
        rawModelID: String,
        endpoint: AIProviderEndpoint,
        transport: any HTTPTransport
    ) async throws -> AsyncThrowingStream<StreamChunk, Error> {
        let cleanKey = endpoint.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        var headers = [
            "Accept": "text/event-stream",
            "Content-Type": "application/json",
        ]
        if !cleanKey.isEmpty {
            headers["Authorization"] = "Bearer \(cleanKey)"
            headers["x-goog-api-key"] = cleanKey
        }

        var systemTexts: [String] = []
        var contents: [JSONValue] = []
        var toolIDToName: [String: String] = [:]

        for msg in request.messages {
            switch msg.role {
            case .system:
                if let t = msg.content, !t.isEmpty { systemTexts.append(t) }
            case .user:
                var parts: [JSONValue] = []
                if let cParts = msg.contentParts, !cParts.isEmpty {
                    for p in cParts {
                        if p["type"]?.stringValue == "text", let t = p["text"]?.stringValue, !t.isEmpty {
                            parts.append(["text": .string(t)])
                        } else if p["type"]?.stringValue == "image_url",
                                  let u = p["image_url"]?["url"]?.stringValue,
                                  let (mime, b64) = splitDataURL(u) {
                            parts.append(["inlineData": ["mimeType": .string(mime), "data": .string(b64)]])
                        }
                    }
                } else if let t = msg.content, !t.isEmpty {
                    parts.append(["text": .string(t)])
                }
                if !parts.isEmpty {
                    contents.append(["role": "user", "parts": .array(parts)])
                }
            case .assistant:
                var parts: [JSONValue] = []
                if let t = msg.content, !t.isEmpty { parts.append(["text": .string(t)]) }
                for call in msg.toolCalls ?? [] {
                    toolIDToName[call.id] = call.function.name
                    let args = JSONValue.parse(call.function.arguments) ?? .object([:])
                    parts.append(["functionCall": ["name": .string(call.function.name), "args": args]])
                }
                if !parts.isEmpty {
                    contents.append(["role": "model", "parts": .array(parts)])
                }
            case .tool:
                let fnName = msg.toolCallID.flatMap { toolIDToName[$0] } ?? "tool"
                contents.append([
                    "role": "user",
                    "parts": .array([
                        [
                            "functionResponse": [
                                "name": .string(fnName),
                                "response": ["result": .string(msg.content ?? "")],
                            ],
                        ],
                    ]),
                ])
            }
        }

        var bodyObj: [String: JSONValue] = ["contents": .array(contents)]
        if !systemTexts.isEmpty {
            bodyObj["systemInstruction"] = ["parts": .array([["text": .string(systemTexts.joined(separator: "\n\n"))]])]
        }
        let functionTools = (request.tools ?? []).filter { $0.type == "function" }
        if !functionTools.isEmpty {
            bodyObj["tools"] = .array([
                [
                    "functionDeclarations": .array(functionTools.map { spec in
                        [
                            "name": .string(spec.function.name),
                            "description": .string(spec.function.description),
                            "parameters": sanitizeGeminiSchema(spec.function.parameters),
                        ]
                    }),
                ],
            ])
        }

        let escapedModel = rawModelID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? rawModelID
        guard let url = URL(string: "\(endpoint.rootURLString)/v1beta/models/\(escapedModel):streamGenerateContent?alt=sse") else {
            throw OpenRouterAPIError(httpStatus: 400, code: "invalid_url", message: "Invalid Gemini endpoint URL on \(endpoint.name).")
        }
        let http = try HTTPRequest.json("POST", url, body: JSONValue.object(bodyObj), headers: headers, idleTimeout: 180)
        let response = try await transport.stream(http)
        guard response.isSuccess else {
            let errBody = try await response.collect(limit: 64 * 1024)
            throw OpenRouterAPIError(status: response.status, body: errBody, headers: response.headers, providerName: endpoint.name)
        }

        let events = response.body.serverSentEvents()
        let providerName = endpoint.name
        return AsyncThrowingStream<StreamChunk, Error> { continuation in
            let task = Task {
                var callIndex = 0
                do {
                    for try await event in events {
                        if event == "[DONE]" { break }
                        guard let json = JSONValue.parse(event) else { continue }
                        let candidate = json["candidates"]?.arrayValue?.first
                        for part in candidate?["content"]?["parts"]?.arrayValue ?? [] {
                            if part["thought"]?.boolValue == true, let t = part["text"]?.stringValue {
                                continuation.yield(StreamChunk(model: rawModelID, provider: providerName, reasoningDelta: t))
                            } else if let t = part["text"]?.stringValue {
                                continuation.yield(StreamChunk(model: rawModelID, provider: providerName, contentDelta: t))
                            } else if let fc = part["functionCall"], let name = fc["name"]?.stringValue {
                                let argsJSON = (fc["args"] ?? .object([:])).jsonString()
                                let idx = callIndex; callIndex += 1
                                let tc = StreamChunk.ToolCallDelta(index: idx, id: "gemini_call_\(idx)", name: name, arguments: argsJSON)
                                continuation.yield(StreamChunk(model: rawModelID, provider: providerName, toolCallDeltas: [tc]))
                            }
                        }
                        if let finish = candidate?["finishReason"]?.stringValue {
                            let u = json["usageMetadata"]
                            let inT = u?["promptTokenCount"]?.intValue ?? 0
                            let outT = u?["candidatesTokenCount"]?.intValue ?? 0
                            continuation.yield(StreamChunk(model: rawModelID, provider: providerName, finishReason: finish.lowercased(), usage: Usage(promptTokens: inT, completionTokens: outT)))
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func sanitizeGeminiSchema(_ schema: JSONValue) -> JSONValue {
        guard var obj = schema.objectValue else { return schema }
        obj.removeValue(forKey: "additionalProperties")
        obj.removeValue(forKey: "$schema")
        if let props = obj["properties"]?.objectValue {
            obj["properties"] = .object(props.mapValues(sanitizeGeminiSchema))
        }
        if let items = obj["items"] {
            obj["items"] = sanitizeGeminiSchema(items)
        }
        return .object(obj)
    }

    private static func splitDataURL(_ dataURL: String) -> (mime: String, base64: String)? {
        guard dataURL.hasPrefix("data:"),
              let comma = dataURL.firstIndex(of: ",") else { return nil }
        let meta = String(dataURL[dataURL.index(dataURL.startIndex, offsetBy: 5)..<comma])
        let mime = meta.split(separator: ";").first.map(String.init) ?? "image/jpeg"
        let b64 = String(dataURL[dataURL.index(after: comma)...])
        guard !b64.isEmpty else { return nil }
        return (mime, b64)
    }

    // MARK: - OpenAI-Compatible Image Generation (`/v1/images/generations`)

    public static func generateImages(
        prompt: String,
        rawModelID: String,
        options: ImageGenerationOptions,
        endpoint: AIProviderEndpoint,
        transport: any HTTPTransport
    ) async throws -> [GeneratedImage] {
        guard let base = endpoint.normalizedURL else {
            throw OpenRouterAPIError(httpStatus: 400, code: "invalid_url", message: "Invalid base URL for \(endpoint.name).")
        }
        try validateEndpointURL(base)
        let cleanKey = endpoint.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        var headers = ["Accept": "application/json"]
        if !cleanKey.isEmpty { headers["Authorization"] = "Bearer \(cleanKey)" }

        let size: String = switch options.aspectRatio {
        case .square: "1024x1024"
        case .portrait, .tall: "1024x1536"
        case .landscape, .wide: "1536x1024"
        }

        let body: JSONValue = [
            "model": .string(rawModelID),
            "prompt": .string(prompt),
            "n": .number(Double(options.count)),
            "size": .string(size),
            "response_format": "b64_json",
        ]
        // Try standard OpenAI `/v1/images/generations` first, falling back to `/v1/images`
        var response = try await transport.send(
            try HTTPRequest.json("POST", base.appendingPathComponent("images/generations"), body: body, headers: headers, idleTimeout: 300)
        )
        if response.status == 404 {
            response = try await transport.send(
                try HTTPRequest.json("POST", base.appendingPathComponent("images"), body: body, headers: headers, idleTimeout: 300)
            )
        }
        guard response.isSuccess else {
            throw OpenRouterAPIError(status: response.status, body: response.body, headers: response.headers, providerName: endpoint.name)
        }
        guard let root = JSONValue.parse(response.body), let items = root["data"]?.arrayValue else {
            throw OpenRouterAPIError(httpStatus: 502, code: "invalid_image_reply", message: "\(endpoint.name) did not return image data.")
        }

        var output: [GeneratedImage] = []
        for item in items {
            if let b64 = item["b64_json"]?.stringValue, let bytes = Data(base64Encoded: b64, options: .ignoreUnknownCharacters) {
                output.append(GeneratedImage(prompt: prompt, model: rawModelID, data: bytes, revisedPrompt: item["revised_prompt"]?.stringValue, options: options))
            } else if let urlStr = item["url"]?.stringValue, let imgURL = URL(string: urlStr) {
                let dl = try await transport.send(HTTPRequest(url: imgURL, idleTimeout: 60))
                if dl.isSuccess, !dl.body.isEmpty {
                    output.append(GeneratedImage(prompt: prompt, model: rawModelID, data: dl.body, revisedPrompt: item["revised_prompt"]?.stringValue, options: options))
                }
            }
        }
        guard !output.isEmpty else {
            throw OpenRouterAPIError(httpStatus: 502, code: "empty_image_reply", message: "\(endpoint.name) returned no image bytes.")
        }
        return output
    }
}
