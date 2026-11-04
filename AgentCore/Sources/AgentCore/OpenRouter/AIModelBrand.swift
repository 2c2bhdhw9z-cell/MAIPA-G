import Foundation

/// The model's brand, not the gateway carrying its requests.
public enum AIModelBrand: String, CaseIterable, Sendable {
    case openAI, xAI, anthropic, gemini, deepSeek, meta, mistral, qwen, kimi
    case miniMax, nvidia, zhipu, cohere, perplexity, microsoft, amazon
    case baidu, tencent, byteDance, stepFun, xiaomi, inclusionAI, ai21, ibm, allenAI
    case liquid, snowflake, reka, upstage, databricks, nousResearch
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
        // The last segment identifies the family; a gateway never lends its logo.
        if model.range(of: "^(gpt|chatgpt|o[0-9]+)([-._: ]|[0-9]|$)", options: .regularExpression) != nil {
            self = .openAI
        } else if let family = Self.familyPrefixes.first(where: { Self.matches(model, families: $0.prefixes) }) {
            self = family.brand
        } else {
            // Exact maker namespaces cover new families without guessing from a gateway.
            switch parts.count > 1 ? String(parts[0]) : "" {
            case "openai": self = .openAI
            case "x-ai", "xai": self = .xAI
            case "anthropic": self = .anthropic
            case "google", "google-deepmind", "gemini": self = .gemini
            case "deepseek": self = .deepSeek
            case "meta", "meta-llama": self = .meta
            case "mistral", "mistralai": self = .mistral
            case "qwen", "alibaba": self = .qwen
            case "moonshot", "moonshotai", "kimi": self = .kimi
            case "minimax": self = .miniMax
            case "nvidia": self = .nvidia
            case "zhipu", "zhipuai", "z-ai", "zai", "thudm": self = .zhipu
            case "cohere", "cohereforai": self = .cohere
            case "perplexity": self = .perplexity
            case "microsoft": self = .microsoft
            case "amazon", "amazon-bedrock": self = .amazon
            case "baidu": self = .baidu
            case "tencent": self = .tencent
            case "bytedance", "bytedance-seed": self = .byteDance
            case "stepfun", "stepfun-ai": self = .stepFun
            case "xiaomi": self = .xiaomi
            case "inclusionai", "inclusion-ai": self = .inclusionAI
            case "ai21", "ai21labs": self = .ai21
            case "ibm", "ibm-granite": self = .ibm
            case "allenai", "allen-ai": self = .allenAI
            case "liquid", "liquidai": self = .liquid
            case "snowflake", "snowflake-arctic": self = .snowflake
            case "reka", "rekaai": self = .reka
            case "upstage": self = .upstage
            case "databricks": self = .databricks
            case "nous", "nousresearch", "nous-research": self = .nousResearch
            case "01-ai", "yi", "internlm": self = .unknown
            default: self = .unknown
            }
        }
    }

    private static let familyPrefixes: [(brand: AIModelBrand, prefixes: [String])] = [
        (.xAI, ["grok"]),
        (.anthropic, ["claude"]),
        (.gemini, ["gemini", "gemma"]),
        (.deepSeek, ["deepseek"]),
        (.meta, ["llama", "meta-llama"]),
        (.mistral, ["mistral", "mixtral", "ministral", "codestral", "magistral", "devstral", "pixtral", "voxtral"]),
        (.qwen, ["qwen", "qwq", "qvq"]),
        (.kimi, ["kimi", "moonshot", "k2"]),
        (.miniMax, ["minimax"]),
        (.nvidia, ["nvidia", "nemotron"]),
        // These families have no matching bundled artwork.
        (.unknown, ["yi", "01-ai", "internlm", "inkling", "thinkingmachines", "thinking-machines"]),
        (.zhipu, ["glm", "zhipu", "chatglm"]),
        (.cohere, ["command", "aya"]),
        (.perplexity, ["sonar"]),
        (.microsoft, ["phi", "microsoft"]),
        (.amazon, ["nova", "titan"]),
        (.baidu, ["ernie"]),
        (.tencent, ["hunyuan"]),
        (.byteDance, ["doubao", "seed"]),
        (.stepFun, ["step"]),
        (.xiaomi, ["mimo"]),
        (.inclusionAI, ["ling", "ring"]),
        (.ai21, ["jamba", "j2", "jurassic"]),
        (.ibm, ["granite"]),
        (.allenAI, ["olmo"]),
        (.liquid, ["lfm"]),
        (.snowflake, ["arctic", "snowflake"]),
        (.reka, ["reka"]),
        (.upstage, ["solar"]),
        (.databricks, ["dbrx"]),
        (.nousResearch, ["hermes", "nous"]),
    ]

    /// Asset names are shared with the app's bundled original-colour imagesets.
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
        case .miniMax: "AIModelMiniMax"
        case .nvidia: "AIModelNVIDIA"
        case .zhipu: "AIModelZhipu"
        case .cohere: "AIModelCohere"
        case .perplexity: "AIModelPerplexity"
        case .microsoft: "AIModelMicrosoft"
        case .amazon: "AIModelAmazon"
        case .baidu: "AIModelBaidu"
        case .tencent: "AIModelTencent"
        case .byteDance: "AIModelByteDance"
        case .stepFun: "AIModelStepFun"
        case .xiaomi: "AIModelXiaomi"
        case .inclusionAI: "AIModelInclusionAI"
        case .ai21: "AIModelAI21"
        case .ibm: "AIModelIBM"
        case .allenAI: "AIModelAllenAI"
        case .liquid: "AIModelLiquid"
        case .snowflake: "AIModelSnowflake"
        case .reka: "AIModelReka"
        case .upstage: "AIModelUpstage"
        case .databricks: "AIModelDatabricks"
        case .nousResearch: "AIModelNousResearch"
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
        case .miniMax: "MiniMax"
        case .nvidia: "NVIDIA"
        case .zhipu: "Zhipu"
        case .cohere: "Cohere"
        case .perplexity: "Perplexity"
        case .microsoft: "Microsoft"
        case .amazon: "Amazon"
        case .baidu: "Baidu"
        case .tencent: "Tencent"
        case .byteDance: "ByteDance"
        case .stepFun: "StepFun"
        case .xiaomi: "Xiaomi"
        case .inclusionAI: "InclusionAI"
        case .ai21: "AI21"
        case .ibm: "IBM"
        case .allenAI: "AllenAI"
        case .liquid: "Liquid"
        case .snowflake: "Snowflake"
        case .reka: "Reka"
        case .upstage: "Upstage"
        case .databricks: "Databricks"
        case .nousResearch: "Nous Research"
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
