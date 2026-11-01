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
            subtitle: "Frontier & TEE enclave models across Claude, GPT, GLM, Kimi & Gemini",
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
        self.apiKey = Self.sanitizeAPIKey(apiKey)
        self.isEnabled = isEnabled
        self.modelWireHints = modelWireHints
    }

    public var assetName: String? {
        AIProviderPreset.matching(id)?.assetName
    }

    public var isReady: Bool {
        isEnabled && !Self.sanitizeAPIKey(apiKey).isEmpty && normalizedURL != nil
    }

    public var normalizedURL: URL? {
        URL(string: Self.normalizeBaseURL(baseURL))
    }

    /// Cleans pasted API keys from dashboards, password managers, `.env` snippets, and `curl` headers
    /// across ALL providers (`OpenRouter`, `OneProvider`, `SayGM`, `TeamoRouter`, `OmniRoute`, `Custom`).
    public static func sanitizeAPIKey(_ raw: String) -> String {
        let zeroWidthScalars: Set<Unicode.Scalar> = [
            "\u{200B}", "\u{200C}", "\u{200D}", "\u{2060}", "\u{FEFF}", "\u{00A0}",
        ]
        var cleaned = String(raw.unicodeScalars.filter { scalar in
            if zeroWidthScalars.contains(scalar) { return false }
            return scalar.value >= 0x20 || scalar == "\t" || scalar == "\n" || scalar == "\r"
        }).trimmingCharacters(in: .whitespacesAndNewlines)

        // If multiple lines were pasted (e.g. a `.env` or `curl` block), pick the first non-comment line that looks like a key/header.
        let lines = cleaned
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        if lines.count > 1 {
            cleaned = lines.first(where: {
                let lower = $0.lowercased()
                return lower.contains("sk-") || lower.contains("bearer ") || lower.contains("api_key") || lower.contains("x-api-key")
            }) ?? lines[0]
        } else if let single = lines.first {
            cleaned = single
        }

        // Strip leading `export ` and `ENV_VAR=` assignment prefixes (e.g. `TEAMO_API_KEY=sk-teamo-...`).
        if cleaned.lowercased().hasPrefix("export ") {
            cleaned = String(cleaned.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let eqIndex = cleaned.firstIndex(of: "=") {
            let lhs = cleaned[..<eqIndex].trimmingCharacters(in: .whitespaces)
            if !lhs.isEmpty, lhs.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) {
                cleaned = String(cleaned[cleaned.index(after: eqIndex)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        // Strip wrapping straight/smart quotes or backticks before and after header prefixes.
        let quoteChars = CharacterSet(charactersIn: "\"'“”‘’`")
        cleaned = cleaned.trimmingCharacters(in: quoteChars).trimmingCharacters(in: .whitespacesAndNewlines)

        // Strip common HTTP header prefixes (`Authorization: Bearer ...`, `Bearer ...`, `x-api-key: ...`).
        let headerPrefixes = [
            "authorization: bearer ",
            "authorization:bearer ",
            "authorization:",
            "x-api-key:",
            "api-key:",
            "bearer ",
        ]
        var strippedPrefix = true
        while strippedPrefix {
            strippedPrefix = false
            let lower = cleaned.lowercased()
            for prefix in headerPrefixes where lower.hasPrefix(prefix) {
                cleaned = String(cleaned.dropFirst(prefix.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: quoteChars)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                strippedPrefix = true
                break
            }
        }

        // Strip trailing shell continuation or semicolon/comma characters from `curl`/JSON snippets.
        while let last = cleaned.last, [",", ";", "\\"].contains(String(last)) {
            cleaned.removeLast()
            cleaned = cleaned.trimmingCharacters(in: quoteChars).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return cleaned
    }

    public static func normalizeBaseURL(_ raw: String) -> String {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        if trimmed.isEmpty { return "" }
        if !trimmed.contains("://") {
            trimmed = "https://" + trimmed
        }
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
        if rawModelID.contains(separator) { return rawModelID }
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

// MARK: - OneProvider Official Public Catalog Metadata

public enum OneProviderOfficialCatalog {
    public struct Entry: Sendable {
        public let name: String
        public let ctx: Int?
        public let maxOut: Int?
        public let inPerM: Double?
        public let outPerM: Double?
        public let cacheReadPerM: Double?
        public let cacheWritePerM: Double?
        public let vision: Bool
        public let tools: Bool
        public let imageOnly: Bool
    }

    /// Official non-chat audio/video endpoints published by OneProvider that do not belong in chat/image pickers.
    public static let excludedAudioVideoIDs: Set<String> = [
        "gemini-2.5-flash-tts", "gemini-2.5-pro-tts", "gemini-3-stt", "gemini-3.1-flash-tts",
        "gemini-3.1-tts", "gemini-3.5-stt", "gemini-3.5-transcribe", "gemini-3.8-flash-lite-tts",
        "gemini-3.8-flash-tts", "grok-stt", "grok-tts", "grok-voice-3.0", "grok-voice-latest",
        "kling-3.0", "kling-3.0-turbo",
    ]

    /// All 74 official OneProvider chat, multimodal, and image-generating models with exact USD/1M pricing.
    public static let entries: [String: Entry] = [
        "claude-fable-5": .init(name: "Claude Fable 5", ctx: 1000000, maxOut: nil, inPerM: 10, outPerM: 50, cacheReadPerM: 1, cacheWritePerM: 12.5, vision: true, tools: true, imageOnly: false),
        "claude-fable-5-1": .init(name: "Claude Fable 5.1", ctx: 1000000, maxOut: nil, inPerM: 10, outPerM: 50, cacheReadPerM: 0.25, cacheWritePerM: 12.5, vision: true, tools: true, imageOnly: false),
        "claude-haiku-4-5": .init(name: "Claude Haiku 4.5", ctx: 200000, maxOut: 64000, inPerM: 1, outPerM: 5, cacheReadPerM: 0.1, cacheWritePerM: 1.25, vision: true, tools: true, imageOnly: false),
        "claude-haiku-4-5-20251001": .init(name: "Claude Haiku 4.5 20251001", ctx: 200000, maxOut: 64000, inPerM: 1, outPerM: 5, cacheReadPerM: 0.1, cacheWritePerM: 1.25, vision: true, tools: true, imageOnly: false),
        "claude-haiku-4-5-20251001-thinking": .init(name: "Claude Haiku 4.5 20251001 Thinking", ctx: nil, maxOut: nil, inPerM: 1, outPerM: 5, cacheReadPerM: 0.1, cacheWritePerM: 1.25, vision: true, tools: true, imageOnly: false),
        "claude-haiku-4-5-thinking": .init(name: "Claude Haiku 4.5 Thinking", ctx: nil, maxOut: nil, inPerM: 1, outPerM: 5, cacheReadPerM: 0.1, cacheWritePerM: 1.25, vision: true, tools: true, imageOnly: false),
        "claude-haiku-5-5": .init(name: "Claude Haiku 5.5", ctx: 1000000, maxOut: 128000, inPerM: 0.1, outPerM: 0.5, cacheReadPerM: 0.01, cacheWritePerM: 0.125, vision: true, tools: true, imageOnly: false),
        "claude-opus-4-7": .init(name: "Claude Opus 4.7", ctx: 1000000, maxOut: 128000, inPerM: 5, outPerM: 25, cacheReadPerM: 0.5, cacheWritePerM: 6.25, vision: true, tools: true, imageOnly: false),
        "claude-opus-4-8": .init(name: "Claude Opus 4.8", ctx: 1000000, maxOut: 128000, inPerM: 5, outPerM: 25, cacheReadPerM: 0.5, cacheWritePerM: 6.25, vision: true, tools: true, imageOnly: false),
        "claude-opus-5": .init(name: "Claude Opus 5", ctx: 1000000, maxOut: 128000, inPerM: 5, outPerM: 25, cacheReadPerM: 0.5, cacheWritePerM: 6.25, vision: true, tools: true, imageOnly: false),
        "claude-opus-5-5": .init(name: "Claude Opus 5.5", ctx: 1000000, maxOut: 128000, inPerM: 4, outPerM: 20, cacheReadPerM: 0.2, cacheWritePerM: 5, vision: true, tools: true, imageOnly: false),
        "claude-opus-5-thinking": .init(name: "Claude Opus 5 Thinking", ctx: nil, maxOut: nil, inPerM: 5, outPerM: 25, cacheReadPerM: 0.5, cacheWritePerM: 6.25, vision: true, tools: true, imageOnly: false),
        "claude-sonnet-4-6": .init(name: "Claude Sonnet 4.6", ctx: 1000000, maxOut: 64000, inPerM: 3, outPerM: 15, cacheReadPerM: 0.3, cacheWritePerM: 3.75, vision: true, tools: true, imageOnly: false),
        "claude-sonnet-5": .init(name: "Claude Sonnet 5", ctx: 1000000, maxOut: nil, inPerM: 2, outPerM: 10, cacheReadPerM: 0.2, cacheWritePerM: 2.5, vision: true, tools: true, imageOnly: false),
        "claude-sonnet-5-5": .init(name: "Claude Sonnet 5.5", ctx: 1000000, maxOut: nil, inPerM: 2, outPerM: 10, cacheReadPerM: 0.1, cacheWritePerM: 2.5, vision: true, tools: true, imageOnly: false),
        "claude-sonnet-5-thinking": .init(name: "Claude Sonnet 5 Thinking", ctx: 1000000, maxOut: nil, inPerM: 2, outPerM: 10, cacheReadPerM: 0.2, cacheWritePerM: 2.5, vision: true, tools: true, imageOnly: false),
        "deepseek-v4-flash": .init(name: "DeepSeek V4 Flash", ctx: 1000000, maxOut: 393216, inPerM: 0.3, outPerM: 1.2, cacheReadPerM: 0.006, cacheWritePerM: 0.3, vision: true, tools: true, imageOnly: false),
        "deepseek-v4-flash-0731": .init(name: "DeepSeek V4 Flash 0731", ctx: 1000000, maxOut: 393216, inPerM: 0.3, outPerM: 1.2, cacheReadPerM: 0.006, cacheWritePerM: 0.3, vision: true, tools: true, imageOnly: false),
        "deepseek-v4-flash-vision-exp": .init(name: "DeepSeek V4 Flash Vision Exp", ctx: 1000000, maxOut: 393216, inPerM: 0.3, outPerM: 1.2, cacheReadPerM: 0.006, cacheWritePerM: 0.3, vision: true, tools: true, imageOnly: false),
        "deepseek-v4-pro": .init(name: "DeepSeek V4 Pro", ctx: 1000000, maxOut: 393216, inPerM: 1.32, outPerM: 3.96, cacheReadPerM: 0.044, cacheWritePerM: 1.32, vision: false, tools: true, imageOnly: false),
        "deepseek-v4-pro-0813": .init(name: "DeepSeek V4 Pro 0813", ctx: 1000000, maxOut: 393216, inPerM: 1.32, outPerM: 3.96, cacheReadPerM: 0.044, cacheWritePerM: 1.32, vision: false, tools: true, imageOnly: false),
        "deepseek-v4.1-flash": .init(name: "DeepSeek V4.1 Flash", ctx: 1000000, maxOut: 393216, inPerM: 0.3, outPerM: 1.2, cacheReadPerM: 0.006, cacheWritePerM: 0.3, vision: true, tools: true, imageOnly: false),
        "deepseek-v4.1-flash-1017": .init(name: "DeepSeek V4.1 Flash 1017", ctx: 1000000, maxOut: 393216, inPerM: 0.3, outPerM: 1.2, cacheReadPerM: 0.006, cacheWritePerM: 0.3, vision: true, tools: true, imageOnly: false),
        "gemini-3-pro-image": .init(name: "Gemini 3 Pro Image", ctx: nil, maxOut: nil, inPerM: 2, outPerM: 12, cacheReadPerM: 2, cacheWritePerM: 2, vision: true, tools: false, imageOnly: true),
        "gemini-3-pro-image-preview": .init(name: "Gemini 3 Pro Image Preview", ctx: nil, maxOut: nil, inPerM: 2, outPerM: 12, cacheReadPerM: 2, cacheWritePerM: 2, vision: true, tools: false, imageOnly: true),
        "gemini-3.1-flash-image": .init(name: "Gemini 3.1 Flash Image", ctx: 131072, maxOut: 32768, inPerM: nil, outPerM: nil, cacheReadPerM: nil, cacheWritePerM: nil, vision: true, tools: false, imageOnly: true),
        "gemini-3.1-flash-image-preview": .init(name: "Gemini 3.1 Flash Image Preview", ctx: 131072, maxOut: 32768, inPerM: 0.5, outPerM: 3, cacheReadPerM: 0.5, cacheWritePerM: 0.5, vision: true, tools: false, imageOnly: true),
        "gemini-3.1-flash-lite": .init(name: "Gemini 3.1 Flash Lite", ctx: 1048576, maxOut: 65536, inPerM: 0.25, outPerM: 1.5, cacheReadPerM: 0.025, cacheWritePerM: 0.25, vision: true, tools: true, imageOnly: false),
        "gemini-3.1-flash-lite-preview": .init(name: "Gemini 3.1 Flash Lite Preview", ctx: 1048576, maxOut: 65536, inPerM: 0.25, outPerM: 1.5, cacheReadPerM: 0.025, cacheWritePerM: 0.25, vision: true, tools: true, imageOnly: false),
        "gemini-3.1-pro": .init(name: "Gemini 3.1 Pro", ctx: 1048576, maxOut: 65536, inPerM: 2, outPerM: 12, cacheReadPerM: 0.2, cacheWritePerM: 2, vision: true, tools: true, imageOnly: false),
        "gemini-3.1-pro-high": .init(name: "Gemini 3.1 Pro High", ctx: 1048576, maxOut: 65536, inPerM: 2, outPerM: 12, cacheReadPerM: 0.2, cacheWritePerM: 2, vision: true, tools: true, imageOnly: false),
        "gemini-3.1-pro-low": .init(name: "Gemini 3.1 Pro Low", ctx: 1048576, maxOut: 65536, inPerM: 2, outPerM: 12, cacheReadPerM: 0.2, cacheWritePerM: 2, vision: true, tools: true, imageOnly: false),
        "gemini-3.1-pro-preview": .init(name: "Gemini 3.1 Pro Preview", ctx: 1048576, maxOut: 65536, inPerM: 2, outPerM: 12, cacheReadPerM: 0.2, cacheWritePerM: 2, vision: true, tools: true, imageOnly: false),
        "gemini-3.1-pro-preview-low": .init(name: "Gemini 3.1 Pro Preview Low", ctx: 1048576, maxOut: 65536, inPerM: 2, outPerM: 12, cacheReadPerM: 0.2, cacheWritePerM: 2, vision: true, tools: true, imageOnly: false),
        "gemini-3.5-flash": .init(name: "Gemini 3.5 Flash", ctx: 1048576, maxOut: 65536, inPerM: 1.5, outPerM: 9, cacheReadPerM: 0.15, cacheWritePerM: 1.5, vision: true, tools: true, imageOnly: false),
        "gemini-3.6-flash": .init(name: "Gemini 3.6 Flash", ctx: 1048576, maxOut: 65536, inPerM: 0.75, outPerM: 3.75, cacheReadPerM: 0.075, cacheWritePerM: 0.75, vision: true, tools: true, imageOnly: false),
        "gemini-3.6-flash-tiered": .init(name: "Gemini 3.6 Flash Tiered", ctx: 1048576, maxOut: 65536, inPerM: 0.75, outPerM: 3.75, cacheReadPerM: 0.075, cacheWritePerM: 0.75, vision: true, tools: true, imageOnly: false),
        "gemini-3.7-flash": .init(name: "Gemini 3.7 Flash", ctx: 1048576, maxOut: 65536, inPerM: 0.75, outPerM: 3.75, cacheReadPerM: 0.075, cacheWritePerM: 0.75, vision: true, tools: true, imageOnly: false),
        "gemini-3.8-flash": .init(name: "Gemini 3.8 Flash", ctx: 1048576, maxOut: 65536, inPerM: 0.75, outPerM: 3.75, cacheReadPerM: 0.075, cacheWritePerM: 0.75, vision: true, tools: true, imageOnly: false),
        "gemini-4-argon": .init(name: "Gemini 4 Argon", ctx: 1048576, maxOut: 65536, inPerM: 2, outPerM: 10, cacheReadPerM: 0.1, cacheWritePerM: 2, vision: true, tools: true, imageOnly: false),
        "glm-5.1": .init(name: "GLM 5.1", ctx: nil, maxOut: nil, inPerM: 1.4, outPerM: 4.4, cacheReadPerM: 0.28, cacheWritePerM: 1, vision: false, tools: true, imageOnly: false),
        "glm-5.2": .init(name: "GLM 5.2", ctx: 1000000, maxOut: 131072, inPerM: 1.4, outPerM: 4.4, cacheReadPerM: 0.26, cacheWritePerM: 1.4, vision: false, tools: true, imageOnly: false),
        "glm-5.3": .init(name: "GLM 5.3", ctx: 1000000, maxOut: 131072, inPerM: 1.4, outPerM: 4.4, cacheReadPerM: 0.26, cacheWritePerM: 1.4, vision: false, tools: true, imageOnly: false),
        "glm-5.3-flash": .init(name: "GLM 5.3 Flash", ctx: 1048576, maxOut: 131072, inPerM: 0.15, outPerM: 0.5, cacheReadPerM: 0.03, cacheWritePerM: 0.15, vision: true, tools: true, imageOnly: false),
        "gpt-5.5": .init(name: "GPT-5.5", ctx: 1050000, maxOut: 128000, inPerM: 5, outPerM: 30, cacheReadPerM: 0.5, cacheWritePerM: 0, vision: true, tools: true, imageOnly: false),
        "gpt-5.6-luna": .init(name: "GPT-5.6 Luna", ctx: 1050000, maxOut: 128000, inPerM: 1, outPerM: 6, cacheReadPerM: 0.1, cacheWritePerM: 1.25, vision: true, tools: true, imageOnly: false),
        "gpt-5.6-sol": .init(name: "GPT-5.6 Sol", ctx: 1050000, maxOut: 128000, inPerM: 5, outPerM: 30, cacheReadPerM: 0.5, cacheWritePerM: 6.25, vision: true, tools: true, imageOnly: false),
        "gpt-5.6-terra": .init(name: "GPT-5.6 Terra", ctx: 1050000, maxOut: 128000, inPerM: 2.5, outPerM: 15, cacheReadPerM: 0.25, cacheWritePerM: 3.125, vision: true, tools: true, imageOnly: false),
        "gpt-6-astra": .init(name: "GPT-6 Astra", ctx: 1100000, maxOut: 128000, inPerM: 10, outPerM: 50, cacheReadPerM: 1, cacheWritePerM: 12.5, vision: true, tools: true, imageOnly: false),
        "gpt-6-luna": .init(name: "GPT-6 Luna", ctx: 1050000, maxOut: 128000, inPerM: 0.1, outPerM: 0.5, cacheReadPerM: 0.01, cacheWritePerM: 0.125, vision: true, tools: true, imageOnly: false),
        "gpt-6-sol": .init(name: "GPT-6 Sol", ctx: 1050000, maxOut: 128000, inPerM: 2, outPerM: 10, cacheReadPerM: 0.2, cacheWritePerM: 2.5, vision: true, tools: true, imageOnly: false),
        "gpt-6.1-sol": .init(name: "GPT-6.1 Sol", ctx: 1050000, maxOut: 128000, inPerM: 2, outPerM: 10, cacheReadPerM: 0.1, cacheWritePerM: 2.5, vision: true, tools: true, imageOnly: false),
        "gpt-6.1-terra": .init(name: "GPT-6.1 Terra", ctx: 1050000, maxOut: 128000, inPerM: 1, outPerM: 5, cacheReadPerM: 0.05, cacheWritePerM: 1.25, vision: true, tools: true, imageOnly: false),
        "gpt-image-2": .init(name: "GPT Image 2", ctx: nil, maxOut: nil, inPerM: 5, outPerM: 10, cacheReadPerM: 1.25, cacheWritePerM: 0, vision: true, tools: false, imageOnly: true),
        "gpt-image-2.5": .init(name: "GPT Image 2.5", ctx: nil, maxOut: nil, inPerM: 5, outPerM: 10, cacheReadPerM: 1.25, cacheWritePerM: 0, vision: true, tools: false, imageOnly: true),
        "gpt-image-2.5-sunburst": .init(name: "GPT Image 2.5 Sunburst", ctx: nil, maxOut: nil, inPerM: 5, outPerM: 10, cacheReadPerM: 1.25, cacheWritePerM: 0, vision: true, tools: false, imageOnly: true),
        "grok-4.5": .init(name: "Grok 4.5", ctx: 500000, maxOut: nil, inPerM: 2, outPerM: 6, cacheReadPerM: 0.3, cacheWritePerM: nil, vision: true, tools: false, imageOnly: false),
        "grok-4.6": .init(name: "Grok 4.6", ctx: 500000, maxOut: nil, inPerM: 2, outPerM: 6, cacheReadPerM: 0.5, cacheWritePerM: nil, vision: true, tools: false, imageOnly: false),
        "grok-4.7": .init(name: "Grok 4.7", ctx: 500000, maxOut: nil, inPerM: 2, outPerM: 6, cacheReadPerM: 0.5, cacheWritePerM: nil, vision: true, tools: false, imageOnly: false),
        "grok-imagine": .init(name: "Grok Imagine", ctx: nil, maxOut: nil, inPerM: nil, outPerM: nil, cacheReadPerM: nil, cacheWritePerM: nil, vision: true, tools: false, imageOnly: true),
        "grok-imagine-image": .init(name: "Grok Imagine Image", ctx: nil, maxOut: nil, inPerM: nil, outPerM: nil, cacheReadPerM: nil, cacheWritePerM: nil, vision: true, tools: false, imageOnly: true),
        "grok-imagine-image-2.0": .init(name: "Grok Imagine Image 2.0", ctx: nil, maxOut: nil, inPerM: nil, outPerM: nil, cacheReadPerM: nil, cacheWritePerM: nil, vision: true, tools: false, imageOnly: true),
        "grok-imagine-image-lite": .init(name: "Grok Imagine Image Lite", ctx: nil, maxOut: nil, inPerM: nil, outPerM: nil, cacheReadPerM: nil, cacheWritePerM: nil, vision: true, tools: false, imageOnly: true),
        "kimi-k2.7-code": .init(name: "Kimi K2.7 Code", ctx: 262144, maxOut: nil, inPerM: 0.95, outPerM: 4, cacheReadPerM: 0.19, cacheWritePerM: 0.95, vision: true, tools: false, imageOnly: false),
        "kimi-k2.7-code-highspeed": .init(name: "Kimi K2.7 Code Highspeed", ctx: 262144, maxOut: nil, inPerM: 1.9, outPerM: 8, cacheReadPerM: 0.38, cacheWritePerM: 1.9, vision: true, tools: false, imageOnly: false),
        "kimi-k3": .init(name: "Kimi K3", ctx: 1048576, maxOut: nil, inPerM: 3, outPerM: 15, cacheReadPerM: 0.3, cacheWritePerM: 3, vision: true, tools: false, imageOnly: false),
        "kimi-k3.1-pro": .init(name: "Kimi K3.1 Pro", ctx: 1048576, maxOut: nil, inPerM: 2, outPerM: 10, cacheReadPerM: 0.2, cacheWritePerM: 2, vision: true, tools: false, imageOnly: false),
        "minimax-m2.7": .init(name: "MiniMax M2.7", ctx: 204800, maxOut: nil, inPerM: 0.3, outPerM: 1.2, cacheReadPerM: 0.06, cacheWritePerM: 0.375, vision: false, tools: true, imageOnly: false),
        "minimax-m3": .init(name: "MiniMax M3", ctx: 1000000, maxOut: nil, inPerM: 0.3, outPerM: 1.2, cacheReadPerM: 0.06, cacheWritePerM: 0.3, vision: true, tools: true, imageOnly: false),
        "minimax-m3.1-flash": .init(name: "MiniMax M3.1 Flash", ctx: 1000000, maxOut: nil, inPerM: 0.15, outPerM: 0.6, cacheReadPerM: 0.015, cacheWritePerM: 0.15, vision: true, tools: true, imageOnly: false),
        "qwen3.7-max": .init(name: "Qwen 3.7 Max", ctx: nil, maxOut: nil, inPerM: 1.65, outPerM: 4.951, cacheReadPerM: 0.165, cacheWritePerM: 2.0625, vision: false, tools: true, imageOnly: false),
        "qwen3.7-plus": .init(name: "Qwen 3.7 Plus", ctx: nil, maxOut: nil, inPerM: 0.4, outPerM: 1.6, cacheReadPerM: 0.08, cacheWritePerM: 0.5, vision: true, tools: true, imageOnly: false),
        "qwen3.8-flash": .init(name: "Qwen 3.8 Flash", ctx: nil, maxOut: nil, inPerM: 0.15, outPerM: 0.47, cacheReadPerM: 0.03, cacheWritePerM: 0.1875, vision: true, tools: true, imageOnly: false),
        "qwen3.8-max": .init(name: "Qwen 3.8 Max", ctx: nil, maxOut: nil, inPerM: 1.65, outPerM: 4.951, cacheReadPerM: 0.33, cacheWritePerM: 2.0625, vision: true, tools: true, imageOnly: false),
    ]
}

// MARK: - Live Catalog Discovery, Balance, & Wire Normalization

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

    /// Fetches the live USD balance for any connected external gateway (OneProvider, TeamoRouter, OmniRoute, SayGM, or OpenAI-compatible billing endpoints).
    public static func fetchBalance(
        for endpoint: AIProviderEndpoint,
        transport: any HTTPTransport
    ) async -> Double? {
        guard let base = endpoint.normalizedURL,
              (try? validateEndpointURL(base)) != nil else { return nil }
        let cleanKey = AIProviderEndpoint.sanitizeAPIKey(endpoint.apiKey)
        guard !cleanKey.isEmpty else { return nil }
        // Single-header Bearer auth only (OneProvider rejects dual Authorization + x-api-key).
        let headers = [
            "Accept": "application/json",
            "Authorization": "Bearer \(cleanKey)",
        ]
        let host = base.host?.lowercased() ?? ""
        let candidatePaths: [String]
        if endpoint.id == "oneprovider" || host.contains("oneprovider") {
            candidatePaths = ["dashboard/balance", "dashboard/billing/credit_grants", "dashboard/billing/subscription"]
        } else if endpoint.id == "teamorouter" || host.contains("teamorouter") {
            candidatePaths = ["billing/balance", "dashboard/balance"]
        } else if endpoint.id == "omniroute" || host.contains("cheaperinference") || host.contains("omniroute") {
            candidatePaths = ["account/balance", "dashboard/balance", "billing/balance"]
        } else {
            candidatePaths = ["account/balance", "billing/balance", "dashboard/balance", "dashboard/billing/credit_grants", "credits"]
        }

        for rel in candidatePaths {
            let url = base.appendingPathComponent(rel)
            guard let resp = try? await transport.send(HTTPRequest(url: url, headers: headers, idleTimeout: 12)),
                  resp.isSuccess,
                  let json = JSONValue.parse(resp.body),
                  let usd = parseBalanceJSON(json) else { continue }
            return usd
        }
        return nil
    }

    public static func parseBalanceJSON(_ json: JSONValue) -> Double? {
        // OmniRoute: `available_usd` (preferred over `balance_usd`)
        if let v = numberFromJSON(json["available_usd"]) ?? numberFromJSON(json["data"]?["available_usd"]) {
            return max(0, v)
        }
        // OneProvider: `balance_usd`
        if let v = numberFromJSON(json["balance_usd"]) ?? numberFromJSON(json["data"]?["balance_usd"]) {
            return max(0, v)
        }
        // TeamoRouter: `{"balance": {"value": "85.320000", "currency": "USD"}}`
        if let v = numberFromJSON(json["balance"]?["value"]) ?? numberFromJSON(json["data"]?["balance"]?["value"]) {
            return max(0, v)
        }
        // Direct numeric `balance` or `remaining_usd` or `total_available` (credit_grants)
        if let v = numberFromJSON(json["balance"]) ?? numberFromJSON(json["data"]?["balance"]) ?? numberFromJSON(json["total_available"]) ?? numberFromJSON(json["credits_remaining"]) {
            return max(0, v)
        }
        // SayGM / nano-dollar wallet shapes (`balance_ndollars` / `available_ndollars`)
        if let nano = numberFromJSON(json["available_ndollars"]) ?? numberFromJSON(json["balance_ndollars"]) ?? numberFromJSON(json["data"]?["balance_ndollars"]) {
            return max(0, nano / 1_000_000_000.0)
        }
        // OpenRouter-style `total_credits - total_usage`
        if let purchased = numberFromJSON(json["data"]?["total_credits"]) ?? numberFromJSON(json["total_credits"]),
           let used = numberFromJSON(json["data"]?["total_usage"]) ?? numberFromJSON(json["total_usage"]) {
            return max(0, purchased - used)
        }
        // OpenAI subscription fallback (`hard_limit_usd`)
        if let hard = numberFromJSON(json["hard_limit_usd"]) {
            return max(0, hard)
        }
        return nil
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

        let cleanKey = AIProviderEndpoint.sanitizeAPIKey(endpoint.apiKey)
        // IMPORTANT: Send ONLY Authorization: Bearer on /v1/models (OneProvider rejects requests carrying both Authorization and x-api-key!).
        var headers: [String: String] = ["Accept": "application/json"]
        if !cleanKey.isEmpty {
            headers["Authorization"] = "Bearer \(cleanKey)"
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
                if response.status == 401 || response.status == 403 {
                    throw OpenRouterAPIError(status: response.status, body: response.body, headers: response.headers, providerName: endpoint.name)
                }
            }
        }

        guard response.isSuccess else {
            throw OpenRouterAPIError(status: response.status, body: response.body, headers: response.headers, providerName: endpoint.name)
        }

        var parsed = parseCatalogPayload(response.body, endpoint: endpoint, pricingOverlay: pricingItems)

        if !pricingItems.isEmpty {
            let seen = Set(parsed.models.map { AIProviderModelID.rawModelID($0.id) })
            for (rawID, entry) in pricingItems where !seen.contains(rawID) {
                if let built = buildModel(from: entry, rawID: rawID, endpoint: endpoint, overlay: nil, allReturnedIDs: seen) {
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
                        contextLength: 1_000_000,
                        maxCompletionTokens: 128_000,
                        inputModalities: ["text", "image"],
                        outputModalities: ["text"],
                        supportedParameters: ["tools", "reasoning"],
                        reasoning: ReasoningCapability(mandatory: false, supportedEfforts: [.low, .medium, .high, .xhigh, .max], defaultEffort: .medium)
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

        let allReturnedIDs = Set(items.compactMap { $0["id"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        let isOneProvider = endpoint.id == "oneprovider" || endpoint.baseURL.lowercased().contains("oneprovider.dev")

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
            if isOneProvider, shouldSkipOneProviderID(rawID, entry: entry, allReturnedIDs: allReturnedIDs) {
                continue
            }
            seen.insert(rawID)
            if let built = buildModel(from: entry, rawID: rawID, endpoint: endpoint, overlay: pricingOverlay[rawID], allReturnedIDs: allReturnedIDs) {
                result.append(built.model)
                if let hint = built.wireHint {
                    hints[rawID] = hint
                }
            }
        }
        return (result, hints)
    }

    private static func shouldSkipOneProviderID(_ rawID: String, entry: JSONValue, allReturnedIDs: Set<String>) -> Bool {
        let lower = rawID.lowercased()
        if OneProviderOfficialCatalog.excludedAudioVideoIDs.contains(lower) { return true }
        if ModelInfo.isNonChatUtilityModel(id: lower) { return true }
        // Keep every official public OneProvider model immediately.
        if OneProviderOfficialCatalog.entries[rawID] != nil || OneProviderOfficialCatalog.entries[lower] != nil {
            return false
        }
        // Keep if OneProvider explicitly attaches pricing or display_name metadata to a new model.
        if entry["pricing"] != nil || entry["display_name"] != nil {
            return false
        }
        // When `/v1/models` returns undocumented bare `{id, object}` legacy/snapshot aliases alongside
        // official catalog models, drop the undocumented aliases.
        let officialOverlap = allReturnedIDs.contains { OneProviderOfficialCatalog.entries[$0] != nil }
        if officialOverlap {
            return true
        }
        return false
    }

    private static func buildModel(
        from entry: JSONValue,
        rawID: String,
        endpoint: AIProviderEndpoint,
        overlay: JSONValue?,
        allReturnedIDs: Set<String>
    ) -> (model: ModelInfo, wireHint: String?)? {
        let lower = rawID.lowercased()
        if ModelInfo.isNonChatUtilityModel(id: lower) || OneProviderOfficialCatalog.excludedAudioVideoIDs.contains(lower) {
            return nil
        }
        let archOut = (entry["architecture"]?["output_modalities"]?.arrayValue ?? []).compactMap { $0.stringValue?.lowercased() }
        if !archOut.isEmpty && !archOut.contains("text") && !archOut.contains("image") {
            return nil
        }
        // Deduplicate vendor-prefixed alias when the bare canonical ID is also present in the same gateway response
        if let slash = rawID.firstIndex(of: "/") {
            let bare = String(rawID[rawID.index(after: slash)...])
            if allReturnedIDs.contains(bare) && endpoint.id != "openrouter" {
                return nil
            }
        }

        let isOneProvider = endpoint.id == "oneprovider" || endpoint.baseURL.lowercased().contains("oneprovider.dev")
        let opMeta = isOneProvider ? (OneProviderOfficialCatalog.entries[rawID] ?? OneProviderOfficialCatalog.entries[lower]) : nil

        let rawDisplayName: String = {
            if let explicit = entry["display_name"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !explicit.isEmpty, explicit != rawID {
                return explicit
            }
            if let overName = overlay?["display_name"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !overName.isEmpty, overName != rawID {
                return overName
            }
            if let opName = opMeta?.name {
                return opName
            }
            if let entryName = entry["name"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !entryName.isEmpty, !entryName.contains("/"), entryName != rawID {
                return entryName
            }
            return prettifyModelSlug(rawID)
        }()
        let cleanTitle = rawDisplayName.contains(":") ? rawDisplayName : "\(endpoint.name): \(rawDisplayName)"

        let explicitCtx: Int? = entry["context_length"]?.intValue
            ?? entry["context_window"]?.intValue
            ?? entry["context_tokens"]?.intValue
        let fallbackCtx: Int? = overlay?["context_window"]?.intValue
            ?? entry["max_context_tokens"]?.intValue
            ?? opMeta?.ctx
        let contextLen: Int = explicitCtx ?? fallbackCtx ?? inferredContextLength(for: lower)

        let explicitMaxOut: Int? = entry["max_completion_tokens"]?.intValue
            ?? entry["max_output_tokens"]?.intValue
        let fallbackMaxOut: Int? = overlay?["max_output_tokens"]?.intValue
            ?? opMeta?.maxOut
        let rawMaxOut: Int? = explicitMaxOut ?? fallbackMaxOut
        let normalizedOut = normalizeReportedMaxOutputTokens(
            reported: rawMaxOut,
            contextLength: contextLen,
            lowerID: lower
        )
        let maxOut: Int = normalizedOut.cap ?? inferredMaxOutputTokens(for: lower)

        let extractedPrices = extractPerTokenPrices(entry: entry, overlay: overlay, opMeta: opMeta, rawID: lower)

        // Wire shape detection
        let shapes = (entry["api_shapes"]?.arrayValue ?? []).compactMap(\.stringValue)
        let gatewaySupportsAnthropicMessages = ["oneprovider", "saygm", "teamorouter", "omniroute"].contains(endpoint.id)
            || endpoint.baseURL.lowercased().contains("oneprovider")
            || endpoint.baseURL.lowercased().contains("saygm")
            || endpoint.baseURL.lowercased().contains("teamorouter")
            || endpoint.baseURL.lowercased().contains("cheaperinference")

        var wireHint: String?
        if shapes.contains("messages") || (gatewaySupportsAnthropicMessages && isClaudeModel(lower)) {
            wireHint = WireProtocol.anthropicMessages.rawValue
        } else if shapes.contains("chat.completions") {
            wireHint = WireProtocol.openAIChatCompletions.rawValue
        } else if shapes.contains("responses") {
            wireHint = WireProtocol.openAIResponses.rawValue
        } else if shapes.contains("streamGenerateContent") || shapes.contains("generateContent") {
            wireHint = WireProtocol.geminiGenerateContent.rawValue
        } else if shapes.contains("images.generations") {
            wireHint = "images.generations"
        }

        // Capabilities & Modalities
        let caps = entry["capabilities"]
        let arch = entry["architecture"]
        var inputMods = (arch?["input_modalities"]?.arrayValue?.compactMap(\.stringValue)) ?? []
        var outputMods = (arch?["output_modalities"]?.arrayValue?.compactMap(\.stringValue)) ?? []

        let isImageGen = opMeta?.imageOnly == true
            || caps?["image_generation"]?.boolValue == true
            || caps?["image_output"]?.boolValue == true
            || shapes.contains("images.generations")
            || lower.contains("flux") || lower.contains("imagen") || lower.contains("gpt-image")
            || lower.contains("ideogram") || lower.contains("grok-imagine")
            || lower.hasSuffix("-image") || lower.contains("-image-preview")

        if outputMods.isEmpty {
            outputMods = isImageGen && !shapes.contains("chat.completions") ? ["image"] : ["text"]
        }
        if inputMods.isEmpty {
            let hasVision: Bool
            if let opVis = opMeta?.vision {
                hasVision = opVis
            } else {
                hasVision = caps?["vision"]?.boolValue == true
                    || caps?["image_input"]?.boolValue == true
                    || lower.contains("claude") || lower.contains("gpt-4") || lower.contains("gpt-5") || lower.contains("gpt-6")
                    || lower.contains("gemini") || lower.contains("vl") || lower.contains("vision")
                    || lower.contains("grok-4") || lower.contains("kimi-k2") || lower.contains("kimi-k3")
                    || lower.contains("qwen3.8") || lower.contains("qwen3.7-plus") || lower.contains("minimax-m3")
            }
            inputMods = hasVision ? ["text", "image"] : ["text"]
        }
        if isClaudeModel(lower) && !inputMods.contains("file") {
            inputMods.append("file")
        }

        var params = Set((entry["supported_parameters"]?.arrayValue ?? []).compactMap(\.stringValue))
        let supportsTools: Bool = {
            if isImageGen && !outputMods.contains("text") { return false }
            if let explicit = caps?["tools"]?.boolValue { return explicit }
            if let opTools = opMeta?.tools { return opTools }
            return true
        }()
        if supportsTools { params.insert("tools") }

        let mandatoryThinking = lower.contains("claude-opus-5-5")
            || lower.contains("claude-opus-5.5")
            || lower.contains("claude-fable")
            || lower.contains("claude-mythos")
            || lower.hasSuffix("-thinking")
            || lower.contains("deepseek-r1")
            || lower == "o1" || lower.hasPrefix("o1-") || lower == "o3" || lower.hasPrefix("o3-") || lower == "o4" || lower.hasPrefix("o4-")
            || lower.contains("qwq")

        let supportsReasoning = !isImageGen && (
            mandatoryThinking
            || params.contains("reasoning")
            || caps?["reasoning"]?.boolValue == true
            || lower.contains("claude-opus") || lower.contains("claude-sonnet") || lower.contains("claude-haiku-4-5") || lower.contains("claude-haiku-5")
            || lower.contains("gpt-5") || lower.contains("gpt-6")
            || lower.contains("reasoner") || lower.contains("thinking")
            || lower.contains("deepseek-v4") || lower.contains("glm-5")
            || lower.contains("gemini-2.5") || lower.contains("gemini-3") || lower.contains("gemini-4")
            || lower.contains("grok-3") || lower.contains("grok-4")
            || lower.contains("kimi-k2") || lower.contains("kimi-k3")
            || lower.contains("minimax-m2") || lower.contains("minimax-m3")
            || lower.contains("qwen3")
        )

        var reasoning: ReasoningCapability?
        if supportsReasoning {
            params.insert("reasoning")
            let efforts: [ThinkingLevel] = mandatoryThinking
                ? [.low, .medium, .high, .xhigh, .max]
                : [.none, .low, .medium, .high, .xhigh, .max]
            reasoning = ReasoningCapability(mandatory: mandatoryThinking, supportedEfforts: efforts, defaultEffort: .medium)
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
            maxCompletionTokens: maxOut,
            hadSyntheticMaxOutput: normalizedOut.wasSynthetic ? true : nil,
            promptPrice: extractedPrices.prompt,
            completionPrice: extractedPrices.completion,
            cacheReadPrice: extractedPrices.cacheRead,
            cacheWritePrice: extractedPrices.cacheWrite,
            inputModalities: inputMods,
            outputModalities: outputMods,
            supportedParameters: params,
            reasoning: reasoning,
            created: createdDate
        )
        return (model, wireHint)
    }

    private struct ExtractedPrices {
        var prompt: Double?
        var completion: Double?
        var cacheRead: Double?
        var cacheWrite: Double?
    }

    private static func extractPerTokenPrices(
        entry: JSONValue,
        overlay: JSONValue?,
        opMeta: OneProviderOfficialCatalog.Entry?,
        rawID: String
    ) -> ExtractedPrices {
        if rawID.hasSuffix("-free") || rawID.hasSuffix(":free") {
            return ExtractedPrices(prompt: 0, completion: 0, cacheRead: 0, cacheWrite: 0)
        }
        // 1. SayGM nano-dollars per 1M tokens (`1e15` nano-dollars = $1/token)
        if let dims = entry["pricing"]?["dimensions"],
           let inNano = dims["input_per_mtok_ndollars"]?.doubleValue,
           let outNano = dims["output_per_mtok_ndollars"]?.doubleValue {
            let cr = dims["cache_read_per_mtok_ndollars"]?.doubleValue.map { $0 / 1_000_000_000_000_000.0 }
            let cw = (dims["cache_write_5m_per_mtok_ndollars"]?.doubleValue ?? dims["cache_write_1h_per_mtok_ndollars"]?.doubleValue).map { $0 / 1_000_000_000_000_000.0 }
            return ExtractedPrices(
                prompt: inNano / 1_000_000_000_000_000.0,
                completion: outNano / 1_000_000_000_000_000.0,
                cacheRead: cr,
                cacheWrite: cw
            )
        }
        // 2. OpenRouter / OmniRoute `pricing.prompt` & `pricing.completion`
        if let p = numberFromJSON(entry["pricing"]?["prompt"]),
           let c = numberFromJSON(entry["pricing"]?["completion"]),
           p >= 0, c >= 0 {
            let scale = (p > 0.01 || c > 0.01) ? 1_000_000.0 : 1.0
            let cr = (numberFromJSON(entry["pricing"]?["input_cache_read"]) ?? numberFromJSON(entry["pricing"]?["cache_read"])).map { $0 / scale }
            let cw = (numberFromJSON(entry["pricing"]?["input_cache_write"]) ?? numberFromJSON(entry["pricing"]?["cache_write"])).map { $0 / scale }
            return ExtractedPrices(prompt: p / scale, completion: c / scale, cacheRead: cr, cacheWrite: cw)
        }
        // 3. TeamoRouter / OmniRoute `cost.input` & `cost.output` (USD per 1M tokens)
        let costObj = entry["cost"] ?? overlay?["cost"] ?? entry["pricing_per_mtok"]
        if let inM = numberFromJSON(costObj?["input"]) ?? numberFromJSON(entry["input_price"]),
           let outM = numberFromJSON(costObj?["output"]) ?? numberFromJSON(entry["output_price"]) {
            let crM = numberFromJSON(costObj?["cache_read"]) ?? numberFromJSON(costObj?["cached_input"]) ?? numberFromJSON(entry["cache_read_price"])
            let cwM = numberFromJSON(costObj?["cache_creation"]) ?? numberFromJSON(costObj?["cache_write_5m"]) ?? numberFromJSON(entry["cache_write_price"])
            return ExtractedPrices(
                prompt: inM / 1_000_000.0,
                completion: outM / 1_000_000.0,
                cacheRead: crM.map { $0 / 1_000_000.0 },
                cacheWrite: cwM.map { $0 / 1_000_000.0 }
            )
        }
        // 4. Official OneProvider catalog fallback
        if let opMeta, let inM = opMeta.inPerM, let outM = opMeta.outPerM {
            return ExtractedPrices(
                prompt: inM / 1_000_000.0,
                completion: outM / 1_000_000.0,
                cacheRead: opMeta.cacheReadPerM.map { $0 / 1_000_000.0 },
                cacheWrite: opMeta.cacheWritePerM.map { $0 / 1_000_000.0 }
            )
        }
        return ExtractedPrices()
    }

    private static func numberFromJSON(_ value: JSONValue?) -> Double? {
        if let d = value?.doubleValue { return d }
        if let s = value?.stringValue, let d = Double(s) { return d }
        return nil
    }

    public static func isClaudeModel(_ lowerID: String) -> Bool {
        lowerID.hasPrefix("claude-") || lowerID.contains("/claude-")
    }

    public static func inferredContextLength(for lowerID: String) -> Int {
        if lowerID.contains("claude-fable") || lowerID.contains("claude-mythos")
            || lowerID.contains("claude-opus-4-7") || lowerID.contains("claude-opus-4-8")
            || lowerID.contains("claude-opus-5") || lowerID.contains("claude-sonnet-4-6")
            || lowerID.contains("claude-sonnet-5") || lowerID.contains("claude-haiku-5")
            || lowerID.contains("deepseek-v4") || lowerID.contains("glm-5.2") || lowerID.contains("glm-5.3")
            || lowerID.contains("kimi-k3") || lowerID.contains("minimax-m3") || lowerID.contains("qwen3.8") {
            return 1_000_000
        }
        if lowerID.contains("gemini") { return 1_048_576 }
        if lowerID.contains("gpt-6-astra") { return 1_100_000 }
        if lowerID.contains("gpt-6") || lowerID.contains("gpt-5.5") || lowerID.contains("gpt-5.6") { return 1_050_000 }
        if lowerID.contains("grok-4") { return 500_000 }
        if lowerID.contains("kimi-k2") { return 262_144 }
        if lowerID.contains("claude") || lowerID.contains("gpt-5") || lowerID.contains("glm") || lowerID.contains("minimax") {
            return 200_000
        }
        return 128_000
    }

    public static func inferredMaxOutputTokens(for lowerID: String) -> Int {
        if lowerID.contains("deepseek-v4") { return 131_072 }
        if lowerID.contains("claude-opus-4-7") || lowerID.contains("claude-opus-4-8")
            || lowerID.contains("claude-opus-5") || lowerID.contains("claude-fable")
            || lowerID.contains("claude-mythos") || lowerID.contains("claude-sonnet-5")
            || lowerID.contains("claude-haiku-5")
            || lowerID.contains("gpt-5.5") || lowerID.contains("gpt-5.6") || lowerID.contains("gpt-6")
            || lowerID.contains("glm-5") {
            return 128_000
        }
        if lowerID.contains("kimi-k3") || lowerID.contains("kimi-k2") {
            return 65_536
        }
        if lowerID.contains("claude-sonnet-4") || lowerID.contains("claude-haiku-4-5") || lowerID.contains("gemini") {
            return 65_536
        }
        return 32_768
    }

    /// Detects synthetic ~75–100% context-fraction provider fallbacks (such as SayGM / LiteLLM reporting
    /// `max_output_tokens = 943,718` = `0.9 * 1,048,576` on Kimi K3.1 Pro, or `max_output_tokens == context_length`).
    public static func isSyntheticMaxOutputCap(reported: Int, contextLength: Int?) -> Bool {
        guard reported > 0, let ctx = contextLength, ctx > 0 else { return false }
        if reported >= ctx { return true }
        if reported > 131_072, Double(reported) >= Double(ctx) * 0.75 {
            return true
        }
        if Double(reported) >= Double(ctx) * 0.85, reported % 1_000 != 0, reported % 1_024 != 0 {
            return true
        }
        return false
    }

    public static func normalizeReportedMaxOutputTokens(
        reported: Int?,
        contextLength: Int?,
        lowerID: String
    ) -> (cap: Int?, wasSynthetic: Bool) {
        guard let reported, reported > 0 else { return (nil, false) }
        if isSyntheticMaxOutputCap(reported: reported, contextLength: contextLength) {
            let inferred = inferredMaxOutputTokens(for: lowerID)
            let safeCap = contextLength.map { min(inferred, max(8_192, $0 / 2)) } ?? inferred
            return (safeCap, true)
        }
        return (reported, false)
    }

    /// Computes a safe outgoing completion token limit across all providers so neither explicit `max_tokens`
    /// nor a gateway's server-side ~90% synthetic default (`943,718`) can ever make `input_tokens + max_tokens`
    /// exceed `context_length`.
    public static func safeOutgoingMaxTokens(
        requested: Int?,
        catalogueModel: ModelInfo?,
        rawModelID: String,
        messages: [APIMessage],
        tools: [ToolSpec]?,
        requireExplicitCap: Bool = false
    ) -> Int? {
        let lower = rawModelID.lowercased()
        let ctx = catalogueModel?.contextLength ?? inferredContextLength(for: lower)
        let estimatedInput = Transcript.estimatedTokens(messages) + Transcript.estimatedToolTokens(tools ?? [])
        let safetyMargin = max(1_024, min(8_192, ctx / 64))
        let rawHeadroom = ctx - estimatedInput - safetyMargin
        let headroom: Int
        if rawHeadroom >= 1_024 {
            headroom = rawHeadroom
        } else if ctx - estimatedInput > 256 {
            headroom = max(256, ctx - estimatedInput - 256)
        } else {
            headroom = 1_024
        }

        if let req = requested, req > 0 {
            let clean = normalizeReportedMaxOutputTokens(reported: req, contextLength: ctx, lowerID: lower).cap ?? req
            return min(clean, headroom)
        }
        if requireExplicitCap || catalogueModel?.hadSyntheticMaxOutput == true {
            let base = catalogueModel?.maxCompletionTokens ?? inferredMaxOutputTokens(for: lower)
            let clean = normalizeReportedMaxOutputTokens(reported: base, contextLength: ctx, lowerID: lower).cap ?? base
            return min(clean, headroom)
        }
        return nil
    }

    /// Formats raw slugs cleanly (`claude-opus-5-5` -> `Claude Opus 5.5`, `gpt-6.1-sol` -> `GPT-6.1 Sol`).
    public static func prettifyModelSlug(_ raw: String) -> String {
        var base = raw.split(separator: "/").last.map(String.init) ?? raw
        if let colon = base.firstIndex(of: ":") {
            base = String(base[..<colon])
        }
        let rawParts = base.split(separator: "-").map(String.init)
        // Collapse single-digit minor versions like `["claude", "opus", "5", "5"]` -> `["claude", "opus", "5.5"]`
        var merged: [String] = []
        var i = 0
        while i < rawParts.count {
            let curr = rawParts[i]
            if i + 1 < rawParts.count,
               curr.allSatisfy(\.isNumber), curr.count <= 2,
               rawParts[i + 1].allSatisfy(\.isNumber), rawParts[i + 1].count <= 2 {
                merged.append("\(curr).\(rawParts[i + 1])")
                i += 2
                continue
            }
            merged.append(curr)
            i += 1
        }
        let upperSet: Set<String> = ["gpt", "glm", "vl", "oss", "tee", "ai", "qwq", "tts", "stt", "r1"]
        let specialMap: [String] = []
        _ = specialMap
        let exactNames: [String: String] = [
            "deepseek": "DeepSeek",
            "minimax": "MiniMax",
            "chatgpt": "ChatGPT",
            "openrouter": "OpenRouter",
            "codestral": "Codestral",
        ]
        var formatted: [String] = []
        for (idx, part) in merged.enumerated() {
            let low = part.lowercased()
            if idx == 0, low == "gpt", merged.count > 1, merged[1].first?.isNumber == true {
                formatted.append("GPT-\(merged[1])")
                continue
            }
            if idx == 1, merged[0].lowercased() == "gpt", part.first?.isNumber == true {
                continue
            }
            if let exact = exactNames[low] {
                formatted.append(exact)
            } else if upperSet.contains(low) {
                formatted.append(low.uppercased())
            } else if low.hasPrefix("v"), low.dropFirst().allSatisfy({ $0.isNumber || $0 == "." }) {
                formatted.append("V" + low.dropFirst())
            } else if low.hasPrefix("k"), low.dropFirst().allSatisfy({ $0.isNumber || $0 == "." }) {
                formatted.append("K" + low.dropFirst())
            } else if low.hasPrefix("m"), low.dropFirst().allSatisfy({ $0.isNumber || $0 == "." }) {
                formatted.append("M" + low.dropFirst())
            } else {
                formatted.append(part.prefix(1).uppercased() + part.dropFirst())
            }
        }
        return formatted.joined(separator: " ")
    }

    // MARK: - Streaming Chat Across OpenAI, Anthropic, Responses, & Gemini Wire Protocols

    public static func resolveWireProtocol(for rawModelID: String, endpoint: AIProviderEndpoint) -> WireProtocol {
        if let hint = endpoint.modelWireHints[rawModelID], let proto = WireProtocol(rawValue: hint) {
            return proto
        }
        let lower = rawModelID.lowercased()
        let host = endpoint.baseURL.lowercased()
        let supportsAnthropicMessages = ["oneprovider", "saygm", "teamorouter", "omniroute"].contains(endpoint.id)
            || host.contains("oneprovider")
            || host.contains("saygm")
            || host.contains("teamorouter")
            || host.contains("cheaperinference")
            || host.contains("anthropic")
        if supportsAnthropicMessages && isClaudeModel(lower) {
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
        catalogueModel: ModelInfo? = nil,
        transport: any HTTPTransport
    ) async throws -> AsyncThrowingStream<StreamChunk, Error> {
        guard let base = endpoint.normalizedURL else {
            throw OpenRouterAPIError(httpStatus: 400, code: "invalid_url", message: "Invalid base URL for \(endpoint.name).")
        }
        try validateEndpointURL(base)
        let proto = resolveWireProtocol(for: rawModelID, endpoint: endpoint)
        switch proto {
        case .anthropicMessages:
            return try await streamAnthropicMessages(request, rawModelID: rawModelID, endpoint: endpoint, catalogueModel: catalogueModel, transport: transport)
        case .geminiGenerateContent:
            return try await streamGeminiGenerateContent(request, rawModelID: rawModelID, endpoint: endpoint, catalogueModel: catalogueModel, transport: transport)
        case .openAIResponses:
            return try await streamOpenAIResponses(request, rawModelID: rawModelID, endpoint: endpoint, base: base, catalogueModel: catalogueModel, transport: transport)
        case .openAIChatCompletions:
            return try await streamOpenAIChatCompletions(request, rawModelID: rawModelID, endpoint: endpoint, base: base, catalogueModel: catalogueModel, transport: transport)
        }
    }

    private static func fallbackCost(for usage: Usage, rawModelID: String, endpoint: AIProviderEndpoint, catalogueModel: ModelInfo?) -> Double? {
        if let existing = usage.cost, existing > 0 { return existing }
        let inPrice: Double?
        let outPrice: Double?
        let crPrice: Double?
        let cwPrice: Double?
        if let m = catalogueModel, m.promptPrice != nil || m.completionPrice != nil {
            inPrice = m.promptPrice
            outPrice = m.completionPrice
            crPrice = m.cacheReadPrice
            cwPrice = m.cacheWritePrice
        } else if (endpoint.id == "oneprovider" || endpoint.baseURL.lowercased().contains("oneprovider")),
                  let op = OneProviderOfficialCatalog.entries[rawModelID] ?? OneProviderOfficialCatalog.entries[rawModelID.lowercased()],
                  let ip = op.inPerM, let opOut = op.outPerM {
            inPrice = ip / 1_000_000.0
            outPrice = opOut / 1_000_000.0
            crPrice = op.cacheReadPerM.map { $0 / 1_000_000.0 }
            cwPrice = op.cacheWritePerM.map { $0 / 1_000_000.0 }
        } else {
            return usage.cost
        }
        guard let inP = inPrice, let outP = outPrice else { return usage.cost }
        if inP == 0 && outP == 0 { return 0 }
        let cachedRead = max(0, usage.cachedTokens ?? 0)
        let cacheWrite = max(0, usage.cacheWriteTokens ?? 0)
        let uncachedInput = max(0, usage.promptTokens - cachedRead - cacheWrite)
        let readRate = crPrice ?? (inP * 0.1)
        let writeRate = cwPrice ?? (inP * 1.25)
        let total = Double(uncachedInput) * inP
            + Double(cachedRead) * readRate
            + Double(cacheWrite) * writeRate
            + Double(max(0, usage.completionTokens)) * outP
        return total
    }

    // 1. Standard OpenAI `/v1/chat/completions`
    private static func streamOpenAIChatCompletions(
        _ request: ChatCompletionRequest,
        rawModelID: String,
        endpoint: AIProviderEndpoint,
        base: URL,
        catalogueModel: ModelInfo?,
        transport: any HTTPTransport
    ) async throws -> AsyncThrowingStream<StreamChunk, Error> {
        let cleanKey = AIProviderEndpoint.sanitizeAPIKey(endpoint.apiKey)
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
        if let maxTokens = safeOutgoingMaxTokens(
            requested: request.maxTokens,
            catalogueModel: catalogueModel,
            rawModelID: rawModelID,
            messages: request.messages,
            tools: request.tools
        ) {
            bodyObj["max_tokens"] = .number(Double(maxTokens))
        }
        if let effort = request.reasoningEffort, effort != .none {
            // Pass exact effort (`minimal`, `low`, `medium`, `high`, `xhigh`, `max`); retry below ONLY if an older upstream rejects `xhigh`/`max`.
            bodyObj["reasoning_effort"] = .string(effort.rawValue)
        }

        let url = base.appendingPathComponent("chat/completions")
        var http = try HTTPRequest.json("POST", url, body: JSONValue.object(bodyObj), headers: headers, idleTimeout: 180)
        var response = try await transport.stream(http)
        if !response.isSuccess, response.status == 400, (bodyObj["reasoning_effort"] != nil || bodyObj["max_tokens"] != nil) {
            let firstErr = try await response.collect(limit: 16 * 1024)
            let errText = String(decoding: firstErr, as: UTF8.self).lowercased()
            var adjusted = false
            if bodyObj["max_tokens"] != nil, errText.contains("max_completion_tokens") {
                bodyObj["max_completion_tokens"] = bodyObj.removeValue(forKey: "max_tokens")
                adjusted = true
            } else if bodyObj["max_tokens"] != nil, (errText.contains("max_tokens") || errText.contains("context_length") || errText.contains("maximum context")) {
                if let currentMax = bodyObj["max_tokens"]?.intValue, currentMax > 4_096 {
                    bodyObj["max_tokens"] = .number(Double(max(2_048, currentMax / 2)))
                } else {
                    bodyObj.removeValue(forKey: "max_tokens")
                }
                adjusted = true
            }
            if bodyObj["reasoning_effort"] != nil, (errText.contains("reasoning_effort") || errText.contains("effort") || errText.contains("xhigh") || errText.contains("max")) {
                if request.reasoningEffort == .xhigh || request.reasoningEffort == .max {
                    bodyObj["reasoning_effort"] = "high"
                } else {
                    bodyObj.removeValue(forKey: "reasoning_effort")
                }
                adjusted = true
            }
            if adjusted {
                http = try HTTPRequest.json("POST", url, body: JSONValue.object(bodyObj), headers: headers, idleTimeout: 180)
                response = try await transport.stream(http)
            } else {
                throw OpenRouterAPIError(status: response.status, body: firstErr, headers: response.headers, providerName: endpoint.name)
            }
        }
        guard response.isSuccess else {
            let errBody = try await response.collect(limit: 64 * 1024)
            throw OpenRouterAPIError(status: response.status, body: errBody, headers: response.headers, providerName: endpoint.name)
        }

        let canonicalModelID = AIProviderModelID.encode(providerID: endpoint.id, rawModelID: rawModelID)
        let contentType = response.headers["content-type"]?.lowercased() ?? ""
        if contentType.contains("application/json") && !contentType.contains("event-stream") {
            let fullBody = try await response.collect(limit: 4 * 1024 * 1024)
            return AsyncThrowingStream { continuation in
                if let json = JSONValue.parse(fullBody) {
                    var chunk = StreamChunk(json: json)
                    if chunk.provider == nil { chunk.provider = endpoint.name }
                    chunk.model = chunk.model.map { AIProviderModelID.encode(providerID: endpoint.id, rawModelID: $0) } ?? canonicalModelID
                    if var u = chunk.usage {
                        u.cost = fallbackCost(for: u, rawModelID: rawModelID, endpoint: endpoint, catalogueModel: catalogueModel)
                        chunk.usage = u
                    }
                    continuation.yield(chunk)
                }
                continuation.finish()
            }
        }

        let events = response.body.serverSentEvents()
        let providerName = endpoint.name
        let providerID = endpoint.id
        return AsyncThrowingStream<StreamChunk, Error> { continuation in
            let task = Task {
                do {
                    for try await event in events {
                        if event == "[DONE]" { break }
                        guard let json = JSONValue.parse(event) else { continue }
                        var chunk = StreamChunk(json: json)
                        if chunk.provider == nil { chunk.provider = providerName }
                        if let m = chunk.model {
                            chunk.model = AIProviderModelID.encode(providerID: providerID, rawModelID: m)
                        } else {
                            chunk.model = canonicalModelID
                        }
                        if var u = chunk.usage {
                            u.cost = fallbackCost(for: u, rawModelID: rawModelID, endpoint: endpoint, catalogueModel: catalogueModel)
                            chunk.usage = u
                        }
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
            let sanitized = parts.map { part -> JSONValue in
                if part["type"]?.stringValue == "file" {
                    let name = part["file"]?["filename"]?.stringValue ?? "document.pdf"
                    if let fileData = part["file"]?["file_data"]?.stringValue,
                       let (_, b64) = splitDataURL(fileData),
                       let pdfBytes = Data(base64Encoded: b64, options: .ignoreUnknownCharacters) {
                        return ["type": "text", "text": .string(PDFTextExtractor.formattedAttachmentBlock(name: name, data: pdfBytes))]
                    }
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

    // 2. Native Anthropic `/v1/messages` (for Claude models on OneProvider, SayGM, TeamoRouter, OmniRoute, or Anthropic-compatible URLs)
    private static func streamAnthropicMessages(
        _ request: ChatCompletionRequest,
        rawModelID: String,
        endpoint: AIProviderEndpoint,
        catalogueModel: ModelInfo?,
        transport: any HTTPTransport
    ) async throws -> AsyncThrowingStream<StreamChunk, Error> {
        let cleanKey = AIProviderEndpoint.sanitizeAPIKey(endpoint.apiKey)
        // IMPORTANT: Send ONLY `x-api-key` on `/v1/messages` (never dual `Authorization` + `x-api-key`, which OneProvider rejects).
        var headers = [
            "Accept": "text/event-stream",
            "Content-Type": "application/json",
            "anthropic-version": "2023-06-01",
        ]
        if !cleanKey.isEmpty {
            headers["x-api-key"] = cleanKey
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
                for detail in msg.reasoningDetails ?? [] {
                    if let thought = detail["text"]?.stringValue, let sig = detail["signature"]?.stringValue, !sig.isEmpty {
                        blocks.append([
                            "type": "thinking",
                            "thinking": .string(thought),
                            "signature": .string(sig),
                        ])
                    } else if detail["type"]?.stringValue == "reasoning.encrypted", let data = detail["data"]?.stringValue, !data.isEmpty {
                        blocks.append([
                            "type": "redacted_thinking",
                            "data": .string(data),
                        ])
                    }
                }
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

        // Add `cache_control: {"type": "ephemeral"}` breakpoint on the last block of the conversation prefix
        // (system + tools + prefix message = 3 breakpoints <= Anthropic max 4 breakpoints).
        let ephemeral: JSONValue = ["type": "ephemeral"]
        var cachedMessages = anthropicMessages
        if let lastMsgIdx = cachedMessages.indices.last,
           var blocks = cachedMessages[lastMsgIdx]["content"]?.arrayValue,
           let lastBlockIdx = blocks.indices.last,
           var lastBlockObj = blocks[lastBlockIdx].objectValue,
           lastBlockObj["type"]?.stringValue != "thinking",
           lastBlockObj["type"]?.stringValue != "redacted_thinking" {
            lastBlockObj["cache_control"] = ephemeral
            blocks[lastBlockIdx] = .object(lastBlockObj)
            cachedMessages[lastMsgIdx]["content"] = .array(blocks)
        }

        let lowerModel = rawModelID.lowercased()
        let anthropicCtx = catalogueModel?.contextLength ?? inferredContextLength(for: lowerModel)
        let anthropicInput = Transcript.estimatedTokens(request.messages) + Transcript.estimatedToolTokens(request.tools ?? [])
        let anthropicHeadroom = max(1_024, anthropicCtx - anthropicInput - max(1_024, min(8_192, anthropicCtx / 64)))
        let requestedMaxTokens = safeOutgoingMaxTokens(
            requested: request.maxTokens,
            catalogueModel: catalogueModel,
            rawModelID: rawModelID,
            messages: request.messages,
            tools: request.tools,
            requireExplicitCap: true
        ) ?? min(inferredMaxOutputTokens(for: lowerModel), anthropicHeadroom)

        var baseBody: [String: JSONValue] = [
            "model": .string(rawModelID),
            "stream": .bool(true),
            "messages": .array(cachedMessages.map(JSONValue.object)),
        ]
        if !systemTexts.isEmpty {
            baseBody["system"] = .array([
                [
                    "type": "text",
                    "text": .string(systemTexts.joined(separator: "\n\n")),
                    "cache_control": ephemeral,
                ],
            ])
        }

        let functionTools = (request.tools ?? []).filter { $0.type == "function" }
        if !functionTools.isEmpty {
            var encodedTools: [JSONValue] = functionTools.map { spec in
                [
                    "name": .string(spec.function.name),
                    "description": .string(spec.function.description),
                    "input_schema": spec.function.parameters,
                ]
            }
            if let lastToolIdx = encodedTools.indices.last, var lastToolObj = encodedTools[lastToolIdx].objectValue {
                lastToolObj["cache_control"] = ephemeral
                encodedTools[lastToolIdx] = .object(lastToolObj)
            }
            baseBody["tools"] = .array(encodedTools)
        }

        let usesAdaptiveThinking = lowerModel.contains("claude-opus-4-6")
            || lowerModel.contains("claude-opus-4-7")
            || lowerModel.contains("claude-opus-4-8")
            || lowerModel.contains("claude-opus-5")
            || lowerModel.contains("claude-sonnet-4-6")
            || lowerModel.contains("claude-sonnet-5")
            || lowerModel.contains("claude-haiku-5")
            || lowerModel.contains("claude-fable")
            || lowerModel.contains("claude-mythos")

        let mandatoryAdaptive = lowerModel.contains("claude-opus-5-5")
            || lowerModel.contains("claude-opus-5.5")
            || lowerModel.contains("claude-fable")
            || lowerModel.contains("claude-mythos")

        func buildThinkingPayload(mode: Int) -> [String: JSONValue] {
            var body = baseBody
            var maxOut = requestedMaxTokens
            let effectiveEffort: ThinkingLevel? = {
                if let e = request.reasoningEffort {
                    if e == .none && mandatoryAdaptive { return .low }
                    return e
                }
                return mandatoryAdaptive ? .medium : nil
            }()

            if mode == 0 {
                if usesAdaptiveThinking {
                    if let effort = effectiveEffort {
                        if effort == .none {
                            body["thinking"] = ["type": "disabled"]
                        } else {
                            let effortWire: String = effort == .minimal ? "low" : effort.rawValue
                            body["thinking"] = ["type": "adaptive", "display": "summarized"]
                            body["output_config"] = ["effort": .string(effortWire)]
                        }
                    }
                } else if let effort = effectiveEffort, effort != .none, !lowerModel.contains("haiku-3") {
                    let maxAllowedBudget = max(1_024, anthropicHeadroom - 2_048)
                    let budget = min(classicThinkingBudget(for: effort), maxAllowedBudget)
                    maxOut = min(anthropicHeadroom, max(maxOut, budget + 2_048))
                    if budget >= 1_024, maxOut > budget {
                        body["thinking"] = ["type": "enabled", "budget_tokens": .number(Double(budget))]
                    }
                }
            } else if mode == 1 {
                if let effort = effectiveEffort, effort != .none {
                    let effortWire: String = (effort == .minimal) ? "low" : effort.rawValue
                    body["thinking"] = ["type": "adaptive"]
                    body["output_config"] = ["effort": .string(effortWire)]
                }
            } else {
                maxOut = min(maxOut, min(32_768, anthropicHeadroom))
                if let effort = effectiveEffort, effort != .none, !lowerModel.contains("haiku-3") {
                    let maxAllowedBudget = max(1_024, maxOut - 2_048)
                    let budget = min(min(classicThinkingBudget(for: effort), 24_576), maxAllowedBudget)
                    maxOut = min(anthropicHeadroom, max(maxOut, budget + 2_048))
                    if budget >= 1_024, maxOut > budget {
                        body["thinking"] = ["type": "enabled", "budget_tokens": .number(Double(budget))]
                    }
                }
            }
            body["max_tokens"] = .number(Double(min(maxOut, anthropicHeadroom)))
            return body
        }

        guard let messagesURL = URL(string: endpoint.rootURLString + "/v1/messages") else {
            throw OpenRouterAPIError(httpStatus: 400, code: "invalid_url", message: "Invalid Anthropic messages URL for \(endpoint.name).")
        }

        var response: HTTPStreamResponse?
        var lastErrBody = Data()
        var lastStatus = 400
        var lastHeaders: [String: String] = [:]

        for mode in 0...2 {
            let candidateBody = buildThinkingPayload(mode: mode)
            let http = try HTTPRequest.json("POST", messagesURL, body: JSONValue.object(candidateBody), headers: headers, idleTimeout: 180)
            let attempt = try await transport.stream(http)
            if attempt.isSuccess {
                response = attempt
                break
            }
            let collected = try await attempt.collect(limit: 64 * 1024)
            lastErrBody = collected
            lastStatus = attempt.status
            lastHeaders = attempt.headers
            let lowerErr = String(decoding: collected, as: UTF8.self).lowercased()
            let canFallback = attempt.status == 400 && (
                lowerErr.contains("thinking") || lowerErr.contains("adaptive") || lowerErr.contains("display")
                || lowerErr.contains("output_config") || lowerErr.contains("effort") || lowerErr.contains("max_tokens")
            )
            if !canFallback {
                throw OpenRouterAPIError(status: attempt.status, body: collected, headers: attempt.headers, providerName: endpoint.name)
            }
        }

        guard let response else {
            throw OpenRouterAPIError(status: lastStatus, body: lastErrBody, headers: lastHeaders, providerName: endpoint.name)
        }

        let events = response.body.serverSentEvents()
        let providerName = endpoint.name
        let providerID = endpoint.id
        let canonicalModelID = AIProviderModelID.encode(providerID: providerID, rawModelID: rawModelID)

        return AsyncThrowingStream<StreamChunk, Error> { continuation in
            let task = Task {
                var uncachedInputTokens = 0
                var cacheReadTokens = 0
                var cacheWriteTokens = 0
                var outputTokens = 0
                var msgID: String?
                var modelSeen = canonicalModelID
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
                            if let rawSeen = m?["model"]?.stringValue, !rawSeen.isEmpty {
                                modelSeen = AIProviderModelID.encode(providerID: providerID, rawModelID: rawSeen)
                            }
                            if let u = m?["usage"] {
                                uncachedInputTokens = u["input_tokens"]?.intValue ?? uncachedInputTokens
                                cacheReadTokens = u["cache_read_input_tokens"]?.intValue ?? cacheReadTokens
                                cacheWriteTokens = u["cache_creation_input_tokens"]?.intValue ?? cacheWriteTokens
                            }
                        case "content_block_start":
                            let blockIdx = json["index"]?.intValue ?? 0
                            let cb = json["content_block"]
                            let cbType = cb?["type"]?.stringValue ?? ""
                            if cbType == "tool_use" {
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
                            } else if cbType == "redacted_thinking", let encData = cb?["data"]?.stringValue {
                                continuation.yield(StreamChunk(
                                    id: msgID,
                                    model: modelSeen,
                                    provider: providerName,
                                    reasoningDetails: [["type": "reasoning.encrypted", "data": .string(encData), "index": .number(Double(blockIdx))]]
                                ))
                            }
                        case "content_block_delta":
                            let blockIdx = json["index"]?.intValue ?? 0
                            let delta = json["delta"]
                            let dType = delta?["type"]?.stringValue ?? ""
                            if dType == "text_delta", let text = delta?["text"]?.stringValue {
                                continuation.yield(StreamChunk(id: msgID, model: modelSeen, provider: providerName, contentDelta: text))
                            } else if dType == "thinking_delta", let thought = delta?["thinking"]?.stringValue {
                                continuation.yield(StreamChunk(
                                    id: msgID,
                                    model: modelSeen,
                                    provider: providerName,
                                    reasoningDelta: thought,
                                    reasoningDetails: [["type": "reasoning.text", "text": .string(thought), "index": .number(Double(blockIdx)), "format": "anthropic-claude-v1"]]
                                ))
                            } else if dType == "signature_delta", let sig = delta?["signature"]?.stringValue {
                                continuation.yield(StreamChunk(
                                    id: msgID,
                                    model: modelSeen,
                                    provider: providerName,
                                    reasoningDetails: [["type": "reasoning.text", "signature": .string(sig), "index": .number(Double(blockIdx)), "format": "anthropic-claude-v1"]]
                                ))
                            } else if dType == "input_json_delta", let partial = delta?["partial_json"]?.stringValue {
                                let tIdx = blockToToolIndex[blockIdx] ?? 0
                                let tc = StreamChunk.ToolCallDelta(index: tIdx, arguments: partial)
                                continuation.yield(StreamChunk(id: msgID, model: modelSeen, provider: providerName, toolCallDeltas: [tc]))
                            }
                        case "message_delta":
                            let stop = json["delta"]?["stop_reason"]?.stringValue
                            if let u = json["usage"] {
                                if let outTok = u["output_tokens"]?.intValue { outputTokens = outTok }
                                if let inTok = u["input_tokens"]?.intValue { uncachedInputTokens = inTok }
                                if let crTok = u["cache_read_input_tokens"]?.intValue { cacheReadTokens = crTok }
                                if let cwTok = u["cache_creation_input_tokens"]?.intValue { cacheWriteTokens = cwTok }
                            }
                            let finish: String? = switch stop {
                            case "max_tokens": "length"
                            case "tool_use": "tool_calls"
                            case .some: "stop"
                            case nil: nil
                            }
                            let totalPrompt = uncachedInputTokens + cacheReadTokens + cacheWriteTokens
                            var usage = Usage(
                                promptTokens: totalPrompt,
                                completionTokens: outputTokens,
                                cachedTokens: cacheReadTokens > 0 ? cacheReadTokens : nil,
                                cacheWriteTokens: cacheWriteTokens > 0 ? cacheWriteTokens : nil,
                                cost: json["usage"]?["cost"]?.doubleValue
                            )
                            usage.cost = fallbackCost(for: usage, rawModelID: rawModelID, endpoint: endpoint, catalogueModel: catalogueModel)
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

    private static func classicThinkingBudget(for effort: ThinkingLevel) -> Int {
        switch effort {
        case .none: return 0
        case .minimal: return 1_024
        case .low: return 4_096
        case .medium: return 10_000
        case .high: return 20_000
        case .xhigh: return 32_000
        case .max: return 48_000
        }
    }

    // 3. OpenAI `/v1/responses` (for Responses-only models like `gpt-5.5-pro` on SayGM or Codex models)
    private static func streamOpenAIResponses(
        _ request: ChatCompletionRequest,
        rawModelID: String,
        endpoint: AIProviderEndpoint,
        base: URL,
        catalogueModel: ModelInfo?,
        transport: any HTTPTransport
    ) async throws -> AsyncThrowingStream<StreamChunk, Error> {
        let cleanKey = AIProviderEndpoint.sanitizeAPIKey(endpoint.apiKey)
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
                        if p["type"]?.stringValue == "file" {
                            let name = p["file"]?["filename"]?.stringValue ?? "document.pdf"
                            if let fileData = p["file"]?["file_data"]?.stringValue,
                               let (_, b64) = splitDataURL(fileData),
                               let pdfBytes = Data(base64Encoded: b64, options: .ignoreUnknownCharacters) {
                                return ["type": "input_text", "text": .string(PDFTextExtractor.formattedAttachmentBlock(name: name, data: pdfBytes))]
                            }
                            return ["type": "input_text", "text": .string("[Attached PDF: \(name)]")]
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
        if let effort = request.reasoningEffort, effort != .none {
            bodyObj["reasoning"] = ["effort": .string(effort.rawValue), "summary": "auto"]
        }
        if let maxTokens = safeOutgoingMaxTokens(
            requested: request.maxTokens,
            catalogueModel: catalogueModel,
            rawModelID: rawModelID,
            messages: request.messages,
            tools: request.tools
        ) {
            bodyObj["max_output_tokens"] = .number(Double(maxTokens))
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
        let canonicalModelID = AIProviderModelID.encode(providerID: endpoint.id, rawModelID: rawModelID)
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
                                continuation.yield(StreamChunk(model: canonicalModelID, provider: providerName, contentDelta: d))
                            }
                        case "response.reasoning_summary_text.delta":
                            if let d = json["delta"]?.stringValue {
                                continuation.yield(StreamChunk(model: canonicalModelID, provider: providerName, reasoningDelta: d))
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
                                continuation.yield(StreamChunk(model: canonicalModelID, provider: providerName, toolCallDeltas: [tc]))
                            }
                        case "response.function_call_arguments.delta":
                            let itemID = json["item_id"]?.stringValue ?? ""
                            let idx = itemToCallIndex[itemID] ?? 0
                            if let d = json["delta"]?.stringValue {
                                continuation.yield(StreamChunk(model: canonicalModelID, provider: providerName, toolCallDeltas: [.init(index: idx, arguments: d)]))
                            }
                        case "response.completed":
                            let u = json["response"]?["usage"]
                            let inT = u?["input_tokens"]?.intValue ?? 0
                            let outT = u?["output_tokens"]?.intValue ?? 0
                            let cached = u?["input_tokens_details"]?["cached_tokens"]?.intValue
                            let hasCalls = nextIdx > 0
                            var usage = Usage(promptTokens: inT, completionTokens: outT, cachedTokens: cached)
                            usage.cost = fallbackCost(for: usage, rawModelID: rawModelID, endpoint: endpoint, catalogueModel: catalogueModel)
                            continuation.yield(StreamChunk(model: canonicalModelID, provider: providerName, finishReason: hasCalls ? "tool_calls" : "stop", usage: usage))
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
        catalogueModel: ModelInfo?,
        transport: any HTTPTransport
    ) async throws -> AsyncThrowingStream<StreamChunk, Error> {
        let cleanKey = AIProviderEndpoint.sanitizeAPIKey(endpoint.apiKey)
        var headers = [
            "Accept": "text/event-stream",
            "Content-Type": "application/json",
        ]
        if !cleanKey.isEmpty {
            headers["Authorization"] = "Bearer \(cleanKey)"
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
                        } else if p["type"]?.stringValue == "file",
                                  let fileData = p["file"]?["file_data"]?.stringValue,
                                  let (mime, b64) = splitDataURL(fileData) {
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
        if let maxTokens = safeOutgoingMaxTokens(
            requested: request.maxTokens,
            catalogueModel: catalogueModel,
            rawModelID: rawModelID,
            messages: request.messages,
            tools: request.tools
        ) {
            bodyObj["generationConfig"] = ["maxOutputTokens": .number(Double(maxTokens))]
        }
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
        let canonicalModelID = AIProviderModelID.encode(providerID: endpoint.id, rawModelID: rawModelID)
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
                                continuation.yield(StreamChunk(model: canonicalModelID, provider: providerName, reasoningDelta: t))
                            } else if let t = part["text"]?.stringValue {
                                continuation.yield(StreamChunk(model: canonicalModelID, provider: providerName, contentDelta: t))
                            } else if let fc = part["functionCall"], let name = fc["name"]?.stringValue {
                                let argsJSON = (fc["args"] ?? .object([:])).jsonString()
                                let idx = callIndex; callIndex += 1
                                let tc = StreamChunk.ToolCallDelta(index: idx, id: "gemini_call_\(idx)", name: name, arguments: argsJSON)
                                continuation.yield(StreamChunk(model: canonicalModelID, provider: providerName, toolCallDeltas: [tc]))
                            }
                        }
                        if let finish = candidate?["finishReason"]?.stringValue {
                            let u = json["usageMetadata"]
                            let inT = u?["promptTokenCount"]?.intValue ?? 0
                            let outT = u?["candidatesTokenCount"]?.intValue ?? 0
                            let cached = u?["cachedContentTokenCount"]?.intValue
                            var usage = Usage(promptTokens: inT, completionTokens: outT, cachedTokens: cached)
                            usage.cost = fallbackCost(for: usage, rawModelID: rawModelID, endpoint: endpoint, catalogueModel: catalogueModel)
                            let mappedFinish = callIndex > 0 ? "tool_calls" : finish.lowercased()
                            continuation.yield(StreamChunk(model: canonicalModelID, provider: providerName, finishReason: mappedFinish, usage: usage))
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
        let cleanKey = AIProviderEndpoint.sanitizeAPIKey(endpoint.apiKey)
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
