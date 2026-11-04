import Foundation
import Testing
@testable import AgentCore

@Suite("Bundled AI model brands")
struct AIModelBrandTests {
    @Test("Model families resolve directly and through gateways")
    func modelFamilies() {
        let examples: [(String, AIModelBrand)] = [
            ("openai/gpt-4o", .openAI), ("gpt-5", .openAI),
            ("gpt-oss-120b", .openAI), ("chatgpt-4o-latest", .openAI),
            ("o1", .openAI), ("o3-pro", .openAI), ("o4-mini", .openAI),
            ("x-ai/grok-4", .xAI), ("grok-3-mini", .xAI),
            ("anthropic/claude-sonnet-4.5", .anthropic), ("claude-opus-4-1", .anthropic),
            ("google/gemini-2.5-pro", .gemini), ("gemini-2.0-flash", .gemini),
            ("deepseek/deepseek-r1:free", .deepSeek), ("DeepSeek-V3", .deepSeek),
            ("meta-llama/llama-3.3-70b-instruct", .meta), ("Llama-4-Maverick", .meta),
            ("mistralai/mistral-large", .mistral), ("mixtral-8x7b", .mistral),
            ("codestral-latest", .mistral), ("ministral-8b", .mistral),
            ("qwen/qwen3-235b-a22b", .qwen), ("Qwen2.5-Coder", .qwen),
            ("qwq-32b", .qwen), ("moonshotai/kimi-k2", .kimi),
            ("kimi-k2-thinking", .kimi), ("moonshot-v1-128k", .kimi),
            ("k2-thinking", .kimi), ("google/gemma-3", .gemini),
            ("qvq-72b", .qwen), ("magistral-small", .mistral),
            ("devstral-small", .mistral), ("pixtral-large", .mistral), ("voxtral-mini", .mistral),
            ("gpt-6-astra (fast)", .openAI), ("claude-sonnet-5-5", .anthropic),
            ("x-ai/grok-4.20-multi-agent", .xAI),
            ("minimax/minimax-m3.1-flash", .miniMax),
            ("nvidia/nemotron-3.5-super-vl:free", .nvidia), ("nvidia-3", .nvidia),
            ("thinkingmachines/inkling:free", .unknown),
            ("thinkingmachines-1", .unknown),
            ("thinking-machines/inkling", .unknown), ("inkling", .unknown),
            ("openai/inkling", .unknown), ("openai/thinking-machines-1", .unknown),
            ("deepseek/deepseek-v4.1-flash-1017", .deepSeek),
            ("glm-5", .zhipu), ("zhipu-1", .zhipu), ("chatglm3-6b", .zhipu),
            ("command-r-plus", .cohere), ("aya-expanse-32b", .cohere),
            ("sonar-pro", .perplexity), ("phi-4", .microsoft), ("microsoft-1", .microsoft),
            ("nova-pro", .amazon), ("titan-text", .amazon), ("ernie-4.5", .baidu),
            ("hunyuan-a13b", .tencent), ("doubao-1.5", .byteDance), ("seed-oss", .byteDance),
            ("step-3", .stepFun), ("mimo-v2", .xiaomi),
            ("ling-1t", .inclusionAI), ("ring-1t", .inclusionAI),
            ("jamba-large", .ai21), ("j2-ultra", .ai21), ("jurassic-2", .ai21),
            ("granite-4", .ibm), ("olmo-3", .allenAI), ("lfm2-8b", .liquid),
            ("arctic-instruct", .snowflake), ("snowflake-arctic", .snowflake),
            ("reka-core", .reka), ("solar-pro", .upstage), ("dbrx-instruct", .databricks),
            ("hermes-4", .nousResearch), ("nous-hermes-2", .nousResearch),
            // These makers have no corresponding asset in the requested catalog.
            ("yi-34b", .unknown), ("01-ai/yi-large", .unknown),
            ("01-ai-chat", .unknown), ("internlm/internlm3-8b", .unknown),
            ("auto", .automatic), ("openrouter/auto", .automatic),
            ("free", .free), ("openrouter/free", .free),
        ]
        for (id, expected) in examples {
            for prefix in ["", "oneprovider::", "teamorouter::", "custom-gateway::"] {
                #expect(AIModelBrand(modelID: prefix + id) == expected)
                #expect(AIModelBrand(modelID: " \n" + prefix + id.uppercased() + " ") == expected)
            }
        }
    }

    @Test("Explicit maker namespaces cover otherwise unknown families")
    func makerNamespaces() {
        let makers: [(AIModelBrand, [String])] = [
            (.openAI, ["openai"]), (.xAI, ["x-ai", "xai"]), (.anthropic, ["anthropic"]),
            (.gemini, ["google", "google-deepmind", "gemini"]), (.deepSeek, ["deepseek"]),
            (.meta, ["meta", "meta-llama"]), (.mistral, ["mistral", "mistralai"]),
            (.qwen, ["qwen", "alibaba"]), (.kimi, ["moonshot", "moonshotai", "kimi"]),
            (.miniMax, ["minimax"]), (.nvidia, ["nvidia"]),
            (.unknown, ["thinkingmachines", "thinking-machines"]),
            (.zhipu, ["zhipu", "zhipuai", "z-ai", "zai", "thudm"]),
            (.cohere, ["cohere", "cohereforai"]), (.perplexity, ["perplexity"]),
            (.microsoft, ["microsoft"]), (.amazon, ["amazon", "amazon-bedrock"]),
            (.baidu, ["baidu"]), (.tencent, ["tencent"]),
            (.byteDance, ["bytedance", "bytedance-seed"]), (.stepFun, ["stepfun", "stepfun-ai"]),
            (.xiaomi, ["xiaomi"]), (.inclusionAI, ["inclusionai", "inclusion-ai"]),
            (.ai21, ["ai21", "ai21labs"]), (.ibm, ["ibm", "ibm-granite"]),
            (.allenAI, ["allenai", "allen-ai"]), (.liquid, ["liquid", "liquidai"]),
            (.snowflake, ["snowflake", "snowflake-arctic"]), (.reka, ["reka", "rekaai"]),
            (.upstage, ["upstage"]), (.databricks, ["databricks"]),
            (.nousResearch, ["nous", "nousresearch", "nous-research"]),
            (.unknown, ["01-ai", "yi", "internlm"]),
        ]
        for (expected, namespaces) in makers {
            for namespace in namespaces {
                for prefix in ["", "oneprovider::", "teamorouter::"] {
                    let id = prefix + namespace + "/new-family"
                    #expect(AIModelBrand(modelID: id) == expected)
                    #expect(AIModelBrand(modelID: id.uppercased()) == expected)
                }
                #expect(AIModelBrand(modelID: namespace + "::new-family") == .unknown)
                #expect(AIModelBrand(modelID: "custom/" + namespace + "/new-family") == .unknown)
            }
        }
        #expect(AIModelBrand(modelID: "custom/nested/claude-sonnet-5-5") == .anthropic)
        #expect(AIModelBrand(modelID: "openai/claude-sonnet-5-5") == .anthropic)
    }

    @Test("Unknown names do not borrow a gateway's or substring's logo")
    func unknownModels() {
        for id in ["", "   ", "openai::new-model", "my-gpt-copy", "grokking", "ocean", "qwenish", "custom/auto"] {
            #expect(AIModelBrand(modelID: id) == .unknown)
            #expect(AIModelBrand(modelID: id).assetName == nil)
        }
        let families = [
            "gpt", "chatgpt", "grok", "claude", "gemini", "gemma", "deepseek", "llama",
            "mistral", "qwen", "kimi", "k2", "minimax", "nvidia", "nemotron", "inkling",
            "thinkingmachines", "glm", "zhipu", "chatglm", "command", "aya", "sonar",
            "phi", "microsoft", "nova", "titan", "ernie", "hunyuan", "doubao", "seed",
            "step", "mimo", "ling", "ring", "jamba", "j2", "jurassic", "granite", "olmo",
            "lfm", "arctic", "snowflake", "reka", "solar", "dbrx", "hermes", "nous",
            "yi", "01-ai", "internlm",
        ]
        for family in families {
            for slug in [family + "ish", "my-" + family + "-copy"] {
                for id in [slug, "gateway::custom/" + slug.uppercased()] {
                    #expect(AIModelBrand(modelID: id) == .unknown)
                    #expect(AIModelBrand(modelID: id).assetName == nil)
                }
            }
        }
        #expect(AIModelBrand.initials(for: "gateway::maker/new-model") == "NM")
        #expect(AIModelBrand.initials(for: "gateway::maker/zen") == "Z")
        #expect(AIModelBrand.initials(for: "") == "?")
        #expect(AIModelBrand.initials(for: "///---") == "?")
        #expect(AIModelBrand(modelID: "qwen/qwen3:free") == .qwen)
    }

    @Test("Every brand has a bundled vector imageset and MIT attribution")
    func bundledAssets() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let resources = root.appendingPathComponent("App/Resources")
        var names = Set<String>()
        #expect(AIModelBrand.allCases.filter { $0.assetName != nil }.count == 31)
        #expect(AIModelBrand.openAI.assetName == "AIModelOpenAI")
        #expect(AIModelBrand.nvidia.displayName == "NVIDIA")
        for brand in AIModelBrand.allCases {
            guard let name = brand.assetName else { continue }
            #expect(names.insert(name).inserted)
            let folder = resources.appendingPathComponent("Assets.xcassets/\(name).imageset")
            let data = try Data(contentsOf: folder.appendingPathComponent("Contents.json"))
            let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let images = try #require(json["images"] as? [[String: Any]])
            #expect(images.count == 1)
            let image = try #require(images.first)
            #expect(image["idiom"] as? String == "universal")
            let filename = try #require(image["filename"] as? String)
            #expect(filename.hasSuffix(".svg"))
            let properties = try #require(json["properties"] as? [String: Any])
            #expect(properties["preserves-vector-representation"] as? Bool == true)
            let svg = try String(contentsOf: folder.appendingPathComponent(filename), encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(svg.hasPrefix("<svg "))
            #expect(svg.contains("viewBox="))
            #expect(svg.hasSuffix("</svg>"))
            // Upstream colour artwork may use #RRGGBB or currentColor; monochrome
            // artwork may use short hex, named colours, or SVG's default black.
            // Require a real vector, not a particular palette or 24-point viewBox.
        }
        #expect(names.count == 31)
        let license = try String(contentsOf: resources.appendingPathComponent("LobeIcons-LICENSE.txt"), encoding: .utf8)
        #expect(license.contains("Copyright (c) 2023 LobeHub"))
        #expect(license.contains("THE SOFTWARE IS PROVIDED \"AS IS\""))
        let attribution = try String(contentsOf: resources.appendingPathComponent("LobeIcons-Attribution.txt"), encoding: .utf8)
        #expect(attribution.contains("ea434b96e75813517b377825e01c0df61dee8836"))
    }
}
