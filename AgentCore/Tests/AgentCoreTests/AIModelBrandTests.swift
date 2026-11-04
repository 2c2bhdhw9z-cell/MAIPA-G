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
            ("auto", .automatic), ("openrouter/auto", .automatic),
            ("free", .free), ("openrouter/free", .free),
        ]
        for (id, expected) in examples {
            for prefix in ["", "oneprovider::", "custom-gateway::"] {
                #expect(AIModelBrand(modelID: prefix + id) == expected)
                #expect(AIModelBrand(modelID: " \n" + prefix + id.uppercased() + " ") == expected)
            }
        }
    }

    @Test("Unknown names do not borrow a gateway's or substring's logo")
    func unknownModels() {
        for id in ["", "   ", "openai::new-model", "my-gpt-copy", "grokking", "ocean", "qwenish", "google/gemma-3", "custom/auto"] {
            #expect(AIModelBrand(modelID: id) == .unknown)
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
            #expect(properties["template-rendering-intent"] as? String == "template")
            let svg = try String(contentsOf: folder.appendingPathComponent(filename), encoding: .utf8)
            #expect(svg.hasPrefix("<svg "))
            #expect(svg.contains("viewBox=\"0 0 24 24\""))
            #expect(svg.contains("<path "))
            #expect(svg.hasSuffix("</svg>"))
        }
        #expect(names.count == 9)
        let license = try String(contentsOf: resources.appendingPathComponent("LobeIcons-LICENSE.txt"), encoding: .utf8)
        #expect(license.contains("Copyright (c) 2023 LobeHub"))
        #expect(license.contains("THE SOFTWARE IS PROVIDED \"AS IS\""))
        let attribution = try String(contentsOf: resources.appendingPathComponent("LobeIcons-Attribution.txt"), encoding: .utf8)
        #expect(attribution.contains("ea434b96e75813517b377825e01c0df61dee8836"))
    }
}
