import Foundation
import Testing
@testable import AgentCore

private final class GatewayMockTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var lastRequest: HTTPRequest?
    var sendHandler: (@Sendable (HTTPRequest) -> HTTPResponse)?
    var sseEvents: [String] = []

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        lock.withLock { lastRequest = request }
        return sendHandler?(request) ?? HTTPResponse(status: 200, body: Data("{}".utf8))
    }

    func stream(_ request: HTTPRequest) async throws -> HTTPStreamResponse {
        lock.withLock { lastRequest = request }
        let wire = sseEvents.map { "data: \($0)\n\n" }.joined() + "data: [DONE]\n\n"
        return HTTPStreamResponse(
            status: 200,
            headers: ["content-type": "text/event-stream"],
            body: AsyncThrowingStream { continuation in
                continuation.yield(Data(wire.utf8))
                continuation.finish()
            }
        )
    }
}

@Suite("Multi-Provider AI Gateways, Payload Cap & GitHub Connector")
struct AIProviderAndPayloadTests {
    @Test func sayGMCatalogParsesNanoDollarsAndWireShapes() {
        let payload = """
        {
          "data": [
            {
              "id": "claude-fable-5",
              "owned_by": "anthropic",
              "api_shapes": ["messages"],
              "pricing": {
                "unit": "ndollars_per_mtok",
                "dimensions": {
                  "input_per_mtok_ndollars": 9000000000,
                  "output_per_mtok_ndollars": 45000000000
                }
              },
              "capabilities": {"vision": true, "tools": true}
            },
            {
              "id": "deepseek-v3.2-tee",
              "display_name": "DeepSeek-V3.2",
              "api_shapes": ["chat.completions"],
              "confidential": true,
              "pricing": {
                "unit": "ndollars_per_mtok",
                "dimensions": {
                  "input_per_mtok_ndollars": 1000000000,
                  "output_per_mtok_ndollars": 2000000000
                }
              },
              "capabilities": {"vision": false, "tools": true}
            }
          ]
        }
        """
        let endpoint = AIProviderEndpoint(id: "saygm", name: "SayGM", baseURL: "https://api.saygm.com/v1", apiKey: "sk-test")
        let parsed = AIProviderGateway.parseCatalogPayload(Data(payload.utf8), endpoint: endpoint)
        #expect(parsed.models.count == 2)
        #expect(parsed.wireHints["claude-fable-5"] == "messages")
        #expect(parsed.wireHints["deepseek-v3.2-tee"] == "chat.completions")

        let claude = parsed.models[0]
        #expect(claude.id == "saygm::claude-fable-5")
        #expect(claude.maker == "SayGM")
        #expect(claude.acceptsImages)
        #expect(claude.supportsTools)
        #expect(abs((claude.promptPrice ?? 0) - 0.000009) < 1e-10)
        #expect(abs((claude.completionPrice ?? 0) - 0.000045) < 1e-10)
    }

    @Test func teamoRouterAnthropicMessagesStreamingAndToolUse() async throws {
        let transport = GatewayMockTransport()
        transport.sseEvents = [
            #"{"type":"message_start","message":{"id":"msg_01","model":"claude-sonnet-5-5","usage":{"input_tokens":42}}}"#,
            #"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"Inspecting repo..."}}"#,
            #"{"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}"#,
            #"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Let me check README."}}"#,
            #"{"type":"content_block_start","index":2,"content_block":{"type":"tool_use","id":"toolu_1","name":"read_file"}}"#,
            #"{"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"{\"path\":\"README.md\"}"}}"#,
            #"{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":19}}"#,
        ]

        let teamo = AIProviderEndpoint(
            id: "teamorouter",
            name: "TeamoRouter",
            baseURL: "https://api.teamorouter.com/v1",
            apiKey: "sk-teamo-123"
        )
        let client = OpenRouterClient(transport: transport, apiKey: nil, extraProviders: [teamo])
        let request = ChatCompletionRequest(
            model: "teamorouter::claude-sonnet-5-5",
            messages: [.system("Helpful coder"), .user("Read README")],
            tools: [ToolSpec(name: "read_file", description: "Read file", parameters: ["type": "object"])],
            reasoningEffort: .medium
        )

        var acc = StreamAccumulator()
        let stream = try await client.stream(request)
        for try await chunk in stream {
            acc.apply(chunk)
        }

        #expect(transport.lastRequest?.url.absoluteString == "https://api.teamorouter.com/v1/messages")
        #expect(transport.lastRequest?.headers["x-api-key"] == "sk-teamo-123")
        #expect(acc.reasoning == "Inspecting repo...")
        #expect(acc.text == "Let me check README.")
        #expect(acc.toolCalls == [APIToolCall(id: "toolu_1", name: "read_file", arguments: #"{"path":"README.md"}"#)])
        #expect(acc.usage?.promptTokens == 42)
        #expect(acc.usage?.completionTokens == 19)
    }

    @Test func modelRouterAutoUsesExternalProviderWhenOpenRouterUnsignedIn() {
        let catalogue: [String: ModelInfo] = [
            "oneprovider::claude-sonnet-5-5": ModelInfo(
                id: "oneprovider::claude-sonnet-5-5",
                name: "OneProvider: Claude Sonnet 5.5",
                contextLength: 200_000,
                inputModalities: ["text", "image"],
                outputModalities: ["text"],
                supportedParameters: ["tools", "reasoning"]
            ),
        ]
        let route = ModelRouter.route(
            choice: .auto,
            difficulty: .normal,
            thinking: .medium,
            account: AccountState(),
            catalogue: catalogue,
            openRouterAvailable: false
        )
        #expect(route.model == "oneprovider::claude-sonnet-5-5")
        #expect(route.isAuto)
    }

    @Test func transcriptCapsWireBytesToPreventCloudflare413() {
        let bigFakePNG = String(repeating: "A", count: 3_200_000)
        let oldImageMsg = APIMessage(
            role: .user,
            content: nil,
            contentParts: [
                ["type": "text", "text": "Here are the earlier screenshots"],
                ["type": "image_url", "image_url": ["url": .string("data:image/png;base64,\(bigFakePNG)")]],
                ["type": "image_url", "image_url": ["url": .string("data:image/png;base64,\(bigFakePNG)")]],
                ["type": "image_url", "image_url": ["url": .string("data:image/png;base64,\(bigFakePNG)")]],
            ]
        )
        let assistantMsg = APIMessage.assistant("Got them!")
        let latestMsg = APIMessage.user("Now fix the top button")

        let input: [APIMessage] = [.system("System"), oldImageMsg, assistantMsg, latestMsg]
        #expect(Transcript.estimatedWireBytes(input) > Transcript.defaultMaxPayloadBytes)

        let fitted = Transcript.fit(input, budget: 150_000)
        #expect(fitted.trimmed)
        #expect(Transcript.estimatedWireBytes(fitted.messages) <= Transcript.defaultMaxPayloadBytes)
        #expect(fitted.messages.last?.content == "Now fix the top button")
    }

    @Test func cloudflare413HtmlIsSanitizedAndClassifiedAsContextTooLong() {
        let html = """
        <html>
        <head><title>413 Request Entity Too Large</title></head>
        <body><center><h1>413 Payload Too Large</h1></center><hr><center>cloudflare</center></body>
        </html>
        """
        let err = OpenRouterAPIError(status: 413, body: Data(html.utf8), headers: [:])
        #expect(err.kind == .contextTooLong)
        #expect(!err.message.contains("<html>"))
        #expect(err.message.contains("HTTP 413"))
    }

    @Test func githubConnectorUsesOfficialRESTToolsWithoutBrokenCopilotOAuth() throws {
        let spec = try #require(IntegrationCatalog.byServerID("github"))
        if case .apiKeyREST(let providerKey, let baseURL, _, _, _, _, _, _) = spec.mode {
            #expect(providerKey == "github")
            #expect(baseURL == "https://api.github.com")
        } else {
            Issue.record("Expected github connector to use direct GitHub REST API instead of api.githubcopilot.com OAuth")
        }

        let config = ConnectorConfiguration(
            serverID: "builtin:github",
            displayName: "GitHub",
            kind: .builtin,
            endpoint: URL(string: "https://api.github.com"),
            launchValues: ["provider": "github", "base_url": "https://api.github.com", "auth_style": "bearer"],
            secretNames: ["api_key"]
        )
        let defs = BuiltinIntegrationFactory.definitions(for: config)
        #expect(defs.count == 2)
        #expect(defs.contains { $0.originalName == "search" })
        #expect(defs.contains { $0.originalName == "request" })
    }
}
