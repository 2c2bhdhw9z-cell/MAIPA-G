import Foundation
import Testing
@testable import AgentCore

@Suite("Build 76 — All-Provider Parity, Uncapped Model Capacity, Compaction, & UX")
struct Build76ParityTests {
    @Test("ModelRouter unlocks full 1M–2M context windows and never downgrades Max thinking")
    func fullModelCapacityAndMaxThinking() {
        let opus = ModelInfo(
            id: "oneprovider::claude-opus-5-5",
            name: "OneProvider: Claude Opus 5.5",
            contextLength: 1_000_000,
            maxCompletionTokens: 128_000,
            promptPrice: 4.0 / 1_000_000,
            completionPrice: 20.0 / 1_000_000,
            cacheReadPrice: 0.20 / 1_000_000,
            cacheWritePrice: 5.0 / 1_000_000,
            inputModalities: ["text", "image", "file"],
            outputModalities: ["text"],
            supportedParameters: ["tools", "reasoning"]
        )
        #expect(opus.thinkingLevels == [ThinkingLevel.low, .medium, .high, .xhigh, .max])

        let route = ModelRouter.route(
            choice: .model(opus.id),
            difficulty: .hard,
            thinking: .max,
            account: AccountState(),
            catalogue: [opus.id: opus],
            openRouterAvailable: false
        )
        #expect(route.effort == ThinkingLevel.max)
        #expect(route.contextBudget >= 850_000)

        let twoMillion = ModelInfo(
            id: "google/gemini-pro-2m",
            name: "Google: Gemini Pro 2M",
            contextLength: 2_000_000,
            maxCompletionTokens: 65_536,
            promptPrice: 1.0 / 1_000_000,
            completionPrice: 4.0 / 1_000_000,
            supportedParameters: ["tools", "reasoning"]
        )
        let route2M = ModelRouter.route(
            choice: .model(twoMillion.id),
            difficulty: .normal,
            thinking: .xhigh,
            account: AccountState(),
            catalogue: [twoMillion.id: twoMillion]
        )
        #expect(route2M.effort == ThinkingLevel.xhigh)
        #expect(route2M.contextBudget >= 1_850_000)
    }

    @Test("OneProvider catalog filters out TTS/STT/Kling and enriches cache prices & max output")
    func oneProviderCatalogFilteringAndCachePrices() async throws {
        let mockJSON = """
        {
          "data": [
            { "id": "claude-opus-5-5", "object": "model" },
            { "id": "gpt-6.1-sol", "object": "model" },
            { "id": "tts-1", "object": "model" },
            { "id": "whisper-1", "object": "model" },
            { "id": "kling-v2-master", "object": "model" },
            { "id": "gpt-4o-2024-08-06", "object": "model" }
          ]
        }
        """
        let transport = ClosureHTTPTransport { req in
            if req.url.path.hasSuffix("/models") {
                #expect(req.headers["Authorization"] == "Bearer sk-op-test")
                #expect(req.headers["x-api-key"] == nil)
                return HTTPResponse(status: 200, headers: [:], body: Data(mockJSON.utf8))
            }
            if req.url.path.hasSuffix("/dashboard/balance") {
                return HTTPResponse(status: 200, headers: [:], body: Data("{\"balance_usd\": 42.75}".utf8))
            }
            return HTTPResponse(status: 404)
        }
        let endpoint = AIProviderEndpoint(
            id: "oneprovider",
            name: "OneProvider",
            baseURL: "https://api.oneprovider.dev/v1",
            apiKey: "sk-op-test",
            isEnabled: true
        )
        let fetched = try await AIProviderGateway.fetchModels(for: endpoint, transport: transport)
        let ids = Set(fetched.models.map { $0.id })
        #expect(ids.contains("oneprovider::claude-opus-5-5"))
        #expect(ids.contains("oneprovider::gpt-6.1-sol"))
        #expect(!ids.contains("oneprovider::tts-1"))
        #expect(!ids.contains("oneprovider::whisper-1"))
        #expect(!ids.contains("oneprovider::kling-v2-master"))
        #expect(!ids.contains("oneprovider::gpt-4o-2024-08-06"))

        let opus = try #require(fetched.models.first { $0.id == "oneprovider::claude-opus-5-5" })
        #expect(opus.contextLength == 1_000_000)
        #expect(opus.maxCompletionTokens == 128_000)
        #expect(opus.cacheReadPrice != nil && opus.cacheReadPrice! > 0)
        #expect(opus.shortName == "Claude Opus 5.5")

        let balance = await AIProviderGateway.fetchBalance(for: endpoint, transport: transport)
        #expect(balance == 42.75)
    }

    @Test("External gateways prettify raw model slugs and fetch live balances")
    func externalPrettifiedNamesAndBalances() async {
        #expect(AIProviderGateway.prettifyModelSlug("claude-opus-5-5") == "Claude Opus 5.5")
        #expect(AIProviderGateway.prettifyModelSlug("gpt-5.4-codex") == "GPT-5.4 Codex")

        let teamoTransport = ClosureHTTPTransport { req in
            if req.url.path.contains("/billing/balance") {
                return HTTPResponse(status: 200, headers: [:], body: Data("{\"balance\":{\"value\":\"18.50\"}}".utf8))
            }
            return HTTPResponse(status: 404)
        }
        let teamo = AIProviderEndpoint(id: "teamorouter", name: "TeamoRouter", baseURL: "https://api.teamorouter.com/v1", apiKey: "tr-key", isEnabled: true)
        #expect(await AIProviderGateway.fetchBalance(for: teamo, transport: teamoTransport) == 18.50)

        let omniTransport = ClosureHTTPTransport { req in
            if req.url.path.contains("/account/balance") {
                return HTTPResponse(status: 200, headers: [:], body: Data("{\"available_usd\": 9.25}".utf8))
            }
            return HTTPResponse(status: 404)
        }
        let omni = AIProviderEndpoint(id: "omniroute", name: "OmniRoute", baseURL: "https://api.cheaperinference.com/v1", apiKey: "om-key", isEnabled: true)
        #expect(await AIProviderGateway.fetchBalance(for: omni, transport: omniTransport) == 9.25)
    }

    @Test("Free AI turn cost stays $0.00 when MCPTool leaves billedCost nil")
    func freeTurnCostExcludesEstimatedSpriteCompute() {
        var call = ToolCallRecord(id: "c1", name: "run_shell", arguments: "{}", summary: "Ran ls", status: .done)
        call.billedCost = nil

        var step = AssistantStep()
        step.model = "openrouter/free"
        step.text = "Done!"
        step.toolCalls = [call]
        step.usage = Usage(promptTokens: 500, completionTokens: 80, cost: 0)
        step.finishedAt = Date()

        let turn = AssistantTurn(status: .done, steps: [step], routeLabel: "Free AIs")
        #expect(turn.usage.cost == 0)
    }

    @Test("AgentLoop auto-continues once if a reasoning/tool turn ends with blank visible text")
    func blankTurnAutoContinuesToDeliverReply() async throws {
        let blankWithReasoning = [
            #"{"id":"g1","model":"anthropic/claude-opus-5.5","choices":[{"index":0,"delta":{"reasoning":"Let me analyze this carefully."}}]}"#,
            #"{"id":"g1","choices":[{"index":0,"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":120,"completion_tokens":20,"cost":0.002}}"#
        ]
        let finalVisible = [
            #"{"id":"g2","model":"anthropic/claude-opus-5.5","choices":[{"index":0,"delta":{"content":"Here is the complete answer."}}]}"#,
            #"{"id":"g2","choices":[{"index":0,"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":150,"completion_tokens":15,"cost":0.001}}"#
        ]
        let transport = ScriptedTransport([.events(blankWithReasoning), .events(finalVisible)])
        let environment = AgentEnvironment(
            openRouter: OpenRouterClient(transport: transport, apiKey: "sk-test"),
            freeRoute: { ModelRouter.route(choice: .free, difficulty: .normal, thinking: .medium, account: AccountState(), catalogue: [:]) },
            onOutOfCredits: {}
        )
        var chat = Chat()
        chat.messages = [.user("Explain why."), ChatMessage(body: .assistant(AssistantTurn()))]
        let route = ModelRouter.route(choice: .model("anthropic/claude-opus-5.5"), difficulty: .normal, thinking: .medium, account: AccountState(), catalogue: [:])

        var last: AssistantTurn?
        for await event in AgentLoop.run(AgentTurnInput(chat: chat, route: route, systemPrompt: "Be helpful.", tools: []), environment: environment) {
            if case .updated(let turn, _) = event {
                last = turn
            }
        }
        let finished = try #require(last)
        #expect(finished.status == .done)
        let combined = finished.steps.map { $0.text }.joined()
        #expect(combined.contains("Here is the complete answer."))
        #expect(transport.requestCount == 2)
    }

    @Test("Transcript slims bloated older tool outputs without firing trimmed notice")
    func transcriptSlimsOlderToolOutputsWithoutTrimmedNotice() {
        let hugeToolOutput = String(repeating: "line of verbose log output\n", count: 1_500)
        var oldCall = ToolCallRecord(id: "t1", name: "read_file", arguments: "{\"path\":\"a.swift\"}", summary: "Read a.swift", status: .done)
        oldCall.result = hugeToolOutput

        var oldToolStep = AssistantStep()
        oldToolStep.toolCalls = [oldCall]
        var oldTextStep = AssistantStep()
        oldTextStep.text = "I inspected a.swift."

        var summaryStep = AssistantStep()
        summaryStep.text = "Summary ready."

        var chat = Chat()
        chat.messages = [
            .user("Check a.swift"),
            ChatMessage(body: .assistant(AssistantTurn(status: .done, steps: [oldToolStep, oldTextStep]))),
            .user("Now summarize what you found."),
            ChatMessage(body: .assistant(AssistantTurn(status: .done, steps: [summaryStep]))),
            .user("And one more question?"),
            ChatMessage(body: .assistant(AssistantTurn(status: .done, steps: [summaryStep]))),
            .user("Final follow-up?")
        ]
        let built = Transcript.messages(for: chat, systemPrompt: "System")
        let fitted = Transcript.fit(built, budget: 6_500)
        #expect(fitted.trimmed == false)
        #expect(fitted.messages.contains { $0.role == APIMessage.Role.user && ($0.content?.contains("Check a.swift") == true) })
    }

    @Test("ChangeWorkspace blocks .. path traversal and OAuthURLPolicy discovers origin-root metadata")
    func securityTraversalAndOriginOAuthDiscovery() throws {
        let discovery = try OAuthURLPolicy.authorizationMetadataURLs(for: URL(string: "https://sprites.dev/mcp")!)
        let strings = discovery.map { $0.absoluteString }
        #expect(strings.contains("https://sprites.dev/.well-known/oauth-authorization-server"))
        #expect(throws: MCPAuthorizationError.self) {
            _ = try OAuthURLPolicy.requireSameOrigin(URL(string: "https://evil.example/token")!, as: URL(string: "https://sprites.dev/mcp")!)
        }
        #expect(throws: ChangeWorkspaceError.self) {
            _ = try ChangeWorkspace.safe("../outside.txt")
        }
        #expect(throws: ChangeWorkspaceError.self) {
            _ = try ChangeWorkspace.safe("sub/../../etc/passwd")
        }
    }
}

private final class ClosureHTTPTransport: HTTPTransport, @unchecked Sendable {
    let handler: @Sendable (HTTPRequest) async throws -> HTTPResponse
    init(_ handler: @escaping @Sendable (HTTPRequest) async throws -> HTTPResponse) {
        self.handler = handler
    }
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        try await handler(request)
    }
    func stream(_ request: HTTPRequest) async throws -> HTTPStreamResponse {
        let res = try await handler(request)
        return HTTPStreamResponse(status: res.status, headers: res.headers, body: AsyncThrowingStream {
            if !res.body.isEmpty { $0.yield(res.body) }
            $0.finish()
        })
    }
}
