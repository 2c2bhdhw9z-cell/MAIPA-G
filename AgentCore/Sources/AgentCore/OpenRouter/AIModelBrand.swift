import Foundation

/// The model's brand, not the gateway carrying its requests.
public enum AIModelBrand: String, CaseIterable, Sendable {
    case openAI, xAI, anthropic, gemini, deepSeek, meta, mistral, qwen, kimi
    case automatic, free, unknown

    public init(modelID: String) {
        let raw = Self.rawID(modelID).lowercased()
        if raw == "auto" || raw == "openrouter/auto" {
            self = .automatic
            return
        }
        if raw == "free" || raw == "openrouter/free" {
            self = .free
            return
        }
        let parts = raw.split(separator: "/")
        let model = String(parts.last ?? "")
        // Match family prefixes, never arbitrary substrings in custom model names.
        if model.range(of: "^(gpt|chatgpt|o[0-9]+)([-._:]|[0-9]|$)", options: .regularExpression) != nil {
            self = .openAI
        } else if Self.matches(model, families: ["grok"]) {
            self = .xAI
        } else if Self.matches(model, families: ["claude"]) {
            self = .anthropic
        } else if Self.matches(model, families: ["gemini"]) {
            self = .gemini
        } else if Self.matches(model, families: ["deepseek"]) {
            self = .deepSeek
        } else if Self.matches(model, families: ["llama", "meta-llama"]) {
            self = .meta
        } else if Self.matches(model, families: ["mistral", "mixtral", "ministral", "codestral", "magistral", "devstral", "pixtral", "voxtral"]) {
            self = .mistral
        } else if Self.matches(model, families: ["qwen", "qwq", "qvq"]) {
            self = .qwen
        } else if Self.matches(model, families: ["kimi", "moonshot"]) {
            self = .kimi
        } else {
            // Explicit maker namespaces cover new families without guessing from a gateway.
            switch parts.count > 1 ? String(parts[0]) : "" {
            case "openai": self = .openAI
            case "x-ai", "xai": self = .xAI
            case "anthropic": self = .anthropic
            case "deepseek": self = .deepSeek
            case "meta", "meta-llama": self = .meta
            case "mistral", "mistralai": self = .mistral
            case "qwen": self = .qwen
            case "moonshot", "moonshotai", "kimi": self = .kimi
            default: self = .unknown
            }
        }
    }

    /// Asset names are shared with the app's bundled, monochrome Lobe Icons imagesets.
    public var assetName: String? {
        switch self {
        case .openAI: "AIModelOpenAI"
        case .xAI: "AIModelXAI"
        case .anthropic: "AIModelAnthropic"
        case .gemini: "AIModelGemini"
        case .deepSeek: "AIModelDeepSeek"
        case .meta: "AIModelMeta"
        case .mistral: "AIModelMistral"
        case .qwen: "AIModelQwen"
        case .kimi: "AIModelKimi"
        case .automatic, .free, .unknown: nil
        }
    }

    public var displayName: String {
        switch self {
        case .openAI: "OpenAI"
        case .xAI: "xAI"
        case .anthropic: "Anthropic"
        case .gemini: "Google Gemini"
        case .deepSeek: "DeepSeek"
        case .meta: "Meta"
        case .mistral: "Mistral"
        case .qwen: "Qwen"
        case .kimi: "Moonshot Kimi"
        case .automatic: "Auto"
        case .free: "Free"
        case .unknown: "Unknown model"
        }
    }

    /// A small readable fallback for custom or newly released brands. Never a CPU symbol.
    public static func initials(for modelID: String) -> String {
        let model = rawID(modelID).split(separator: "/").last.map(String.init) ?? ""
        let words = model.split { !$0.isLetter && !$0.isNumber }
        let initials = words.prefix(2).compactMap(\.first).map(String.init).joined()
        return initials.isEmpty ? "?" : initials.uppercased()
    }

    private static func rawID(_ modelID: String) -> String {
        AIProviderModelID.rawModelID(modelID.trimmingCharacters(in: .whitespacesAndNewlines))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func matches(_ model: String, families: [String]) -> Bool {
        families.contains { family in
            guard model.hasPrefix(family) else { return false }
            guard let next = model.dropFirst(family.count).first else { return true }
            return next.isNumber || "-._: ".contains(next)
        }
    }
}
