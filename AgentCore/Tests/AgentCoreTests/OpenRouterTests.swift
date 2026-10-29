import Foundation
import Testing
@testable import AgentCore

@Suite("OpenRouter")
struct OpenRouterTests {
    func chunk(_ json: String) -> StreamChunk {
        StreamChunk(json: JSONValue.parse(json)!)
    }

    @Test func accumulatesTextReasoningAndParallelToolCalls() {
        var accumulator = StreamAccumulator()
        let chunks = [
            #"{"id":"gen-1","model":"anthropic/claude-sonnet-5.5","provider":"Anthropic","choices":[{"index":0,"delta":{"role":"assistant","reasoning":"Let me ","reasoning_details":[{"type":"reasoning.text","text":"Let me ","index":0,"format":"anthropic-claude-v1"}]}}]}"#,
            #"{"id":"gen-1","choices":[{"index":0,"delta":{"reasoning":"look.","reasoning_details":[{"type":"reasoning.text","text":"look.","index":0}]}}]}"#,
            #"{"id":"gen-1","choices":[{"index":0,"delta":{"reasoning_details":[{"type":"reasoning.text","signature":"sig==","index":0}]}}]}"#,
            #"{"id":"gen-1","choices":[{"index":0,"delta":{"content":"Checking "}}]}"#,
            #"{"id":"gen-1","choices":[{"index":0,"delta":{"content":"two files.","tool_calls":[{"index":0,"id":"call_a","type":"function","function":{"name":"read_file","arguments":""}}]}}]}"#,
            #"{"id":"gen-1","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"path\":"}},{"index":1,"id":"call_b","function":{"name":"search_code","arguments":"{\"query\":\"x\"}"}}]}}]}"#,
            #"{"id":"gen-1","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"README.md\"}"}}]},"finish_reason":"tool_calls"}]}"#,
            #"{"id":"gen-1","choices":[{"index":0,"delta":{"content":""},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":1200,"completion_tokens":80,"cost":0.0031,"prompt_tokens_details":{"cached_tokens":1000},"completion_tokens_details":{"reasoning_tokens":20}}}"#,
        ]
        for text in chunks { accumulator.apply(chunk(text)) }

        #expect(accumulator.text == "Checking two files.")
        #expect(accumulator.reasoning == "Let me look.")
        #expect(accumulator.model == "anthropic/claude-sonnet-5.5")
        #expect(accumulator.finishReason == "tool_calls")
        #expect(accumulator.toolCalls == [
            APIToolCall(id: "call_a", name: "read_file", arguments: #"{"path":"README.md"}"#),
            APIToolCall(id: "call_b", name: "search_code", arguments: #"{"query":"x"}"#),
        ])
        #expect(accumulator.reasoningDetails == [
            ["type": "reasoning.text", "text": "Let me look.", "signature": "sig==", "index": 0, "format": "anthropic-claude-v1"],
        ])
        #expect(accumulator.usage?.promptTokens == 1200)
        #expect(accumulator.usage?.cachedTokens == 1000)
        #expect(accumulator.usage?.reasoningTokens == 20)
        #expect(accumulator.usage?.cost == 0.0031)
    }

    @Test func midStreamErrorsAreKept() {
        var accumulator = StreamAccumulator()
        accumulator.apply(chunk(#"{"id":"x","error":{"code":"server_error","message":"Provider disconnected"},"choices":[{"index":0,"delta":{"content":""},"finish_reason":"error"}]}"#))
        #expect(accumulator.error?.kind == .providerFailed)
        #expect(accumulator.finishReason == "error")
        #expect(!accumulator.hasOutput)
    }

    @Test func toolCallsWithoutIndexOrIDStillWork() {
        var accumulator = StreamAccumulator()
        accumulator.apply(chunk(#"{"choices":[{"delta":{"tool_calls":[{"function":{"name":"list_files","arguments":"{}"}}]}}]}"#))
        #expect(accumulator.toolCalls.count == 1)
        #expect(accumulator.toolCalls.first?.function.name == "list_files")
        #expect(accumulator.toolCalls.first?.id.hasPrefix("call_") == true)
    }

    @Test func requestEncodingUsesOpenRouterNames() throws {
        let request = ChatCompletionRequest(
            model: "openrouter/auto",
            messages: [.system("Be brief."), .user("Hi"), APIMessage(role: .assistant, content: nil, toolCalls: [APIToolCall(id: "c1", name: "list_files", arguments: "{}")], reasoningDetails: [["type": "reasoning.encrypted", "data": "abc"]]), .tool(id: "c1", "README.md")],
            tools: [ToolSpec(name: "list_files", description: "List", parameters: ["type": "object"])],
            reasoningEffort: .medium,
            plugins: [["id": "auto-router", "cost_tier": "medium"]],
            sessionID: "chat-1",
            automaticCaching: true
        )
        let json = try #require(JSONValue.parse(try JSONEncoder().encode(request)))
        #expect(json["stream"] == .bool(true))
        #expect(json["reasoning"] == ["effort": "medium"])
        #expect(json["session_id"] == "chat-1")
        #expect(json["cache_control"] == ["type": "ephemeral"])
        #expect(json["tool_choice"] == "auto")
        #expect(json["plugins"] == [["id": "auto-router", "cost_tier": "medium"]])
        let assistant = try #require(json["messages"]?.arrayValue?[2])
        #expect(assistant["content"] == .null)
        #expect(assistant["tool_calls"]?.arrayValue?.first?["function"]?["name"] == "list_files")
        #expect(assistant["reasoning_details"] == [["type": "reasoning.encrypted", "data": "abc"]])
        #expect(json["messages"]?.arrayValue?[3]["tool_call_id"] == "c1")
    }

    @Test func errorKinds() {
        func kind(_ status: Int, _ body: String) -> OpenRouterAPIError.Kind {
            OpenRouterAPIError(status: status, body: Data(body.utf8), headers: [:]).kind
        }
        #expect(kind(402, #"{"error":{"code":402,"message":"Insufficient credits","metadata":{"limit_source":"openrouter_credits"}}}"#) == .outOfCredits)
        #expect(kind(402, #"{"error":{"code":402,"message":"busy","metadata":{"limit_source":"openrouter_in_flight_budget"}}}"#) == .busyRetrySoon)
        #expect(kind(429, #"{"error":{"code":429,"message":"Rate limit exceeded: free-models-per-day. Add 10 credits to unlock 1000 free model requests per day"}}"#) == .freeDailyLimit)
        #expect(kind(429, #"{"error":{"code":429,"message":"Rate limit exceeded"}}"#) == .rateLimited)
        #expect(kind(401, #"{"error":{"code":401,"message":"No auth credentials found"}}"#) == .invalidKey)
        #expect(kind(400, #"{"error":{"code":400,"message":"This endpoint's maximum context length is 32768 tokens"}}"#) == .contextTooLong)
        #expect(kind(503, "<html>busy</html>") == .noModelAvailable)
    }

    @Test func catalogueParsing() throws {
        let catalogue = """
        {"data":[
          {"id":"anthropic/claude-sonnet-5.5","name":"Anthropic: Claude Sonnet 5.5","pricing":{"prompt":"0.000002","completion":"0.00001"},"context_length":1000000,
           "architecture":{"input_modalities":["text","image","file"],"output_modalities":["text"]},
           "supported_parameters":["reasoning","tools","max_tokens"],
           "reasoning":{"mandatory":true,"supported_efforts":["max","xhigh","high","medium","low"],"default_effort":"high"}},
          {"id":"openrouter/auto","name":"Auto Router","pricing":{"prompt":"-1","completion":"-1"},"context_length":2000000,
           "architecture":{"input_modalities":["text"],"output_modalities":["text","image"]},"supported_parameters":["reasoning","tools"],"reasoning":null},
          {"id":"meta-llama/llama-4:free","name":"Meta: Llama 4 (free)","pricing":{"prompt":"0","completion":"0"},"architecture":{"output_modalities":["text"]},"supported_parameters":["tools"]},
          {"id":"anthropic/claude-sonnet-5.5:batch","name":"Batch","pricing":{"prompt":"0.000001","completion":"0.000005"},"architecture":{"output_modalities":["text"]}},
          {"name":"no id, skipped"}
        ]}
        """
        let models = try ModelInfo.parseCatalogue(Data(catalogue.utf8))
        #expect(models.count == 4)
        let sonnet = models[0]
        #expect(sonnet.maker == "Anthropic")
        #expect(sonnet.shortName == "Claude Sonnet 5.5")
        #expect(sonnet.thinkingLevels == [.low, .medium, .high, .xhigh, .max])
        #expect(sonnet.supportsTools && sonnet.acceptsImages && !sonnet.isFree)
        #expect(sonnet.promptPrice == 0.000002)
        let auto = models[1]
        #expect(auto.promptPrice == nil && auto.isRouter)
        #expect(auto.thinkingLevels == [.low, .medium, .high])
        #expect(models[2].isFree && models[2].thinkingLevels.isEmpty)
        #expect(!models[3].isChatModel)
        #expect(ThinkingLevel.medium.nearest(in: [.low, .high]) == .low)
        #expect(ThinkingLevel.none.nearest(in: sonnet.thinkingLevels) == .low)
    }

    @Test func keyInfoParsing() {
        let json = JSONValue.parse(#"{"data":{"label":"MAIPA-G","limit":null,"limit_remaining":null,"usage":0.42,"usage_daily":0.1,"is_free_tier":false,"free_model_daily_requests":{"used":3,"limit":50,"remaining":47}}}"#)!
        let info = OpenRouterKeyInfo(response: json)
        #expect(info.label == "MAIPA-G")
        #expect(!info.isFreeTier)
        #expect(info.usage == 0.42)
        #expect(info.freeRequestsLeftToday == 47)
        #expect(info.limit == nil)
    }

    @Test func multipartAttachmentsAndServerToolsEncode() throws {
        let image = Data([1, 2, 3])
        var chat = Chat()
        let reference = AttachmentReference(name: "photo.jpg", mimeType: "image/jpeg", kind: .image, path: "attachments/x/photo.jpg", bytes: image.count)
        chat.messages = [.user("What is this?", attachments: [reference])]
        let messages = Transcript.messages(for: chat, systemPrompt: "s", attachmentData: [reference.id: image])
        let request = ChatCompletionRequest(model: "openrouter/auto", messages: messages, tools: OpenRouterWebTools.paid)
        let json = try #require(JSONValue.parse(try JSONEncoder().encode(request)))
        let content = try #require(json["messages"]?.arrayValue?[1]["content"]?.arrayValue)
        #expect(content[0]["type"] == "text")
        #expect(content[1]["type"] == "image_url")
        #expect(content[1]["image_url"]?["url"]?.stringValue?.hasPrefix("data:image/jpeg;base64,") == true)
        #expect(json["tools"]?.arrayValue?.map { $0["type"]?.stringValue ?? "" } == ["openrouter:web_search", "openrouter:web_fetch"])
    }

    @Test func streamedCitationsAreRetained() {
        var accumulator = StreamAccumulator()
        accumulator.apply(chunk(#"{"choices":[{"delta":{"content":"Source","annotations":[{"type":"url_citation","url_citation":{"url":"https://example.com/a","title":"Example"}}]}}]}"#))
        #expect(accumulator.citations == [SourceCitation(url: "https://example.com/a", title: "Example")])
    }

    @Test func signInURLCarriesPKCE() {
        let pkce = PKCE(verifier: "dBjftJeZ4CVP-mJ92K9rIn2ky-qD9-kOaeH-SiUpY4U")
        let url = OpenRouterClient.signInURL(callback: URL(string: "https://example.github.io/MAIPA-G/openrouter/")!, pkce: pkce, state: "s1")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.first { $0.name == "code_challenge" }?.value == pkce.challenge)
        #expect(items.first { $0.name == "code_challenge_method" }?.value == "S256")
        #expect(items.first { $0.name == "callback_url" }?.value == "https://example.github.io/MAIPA-G/openrouter/")
        #expect(items.first { $0.name == "state" }?.value == "s1")
    }
}
