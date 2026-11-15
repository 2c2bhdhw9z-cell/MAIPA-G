import Foundation
import Testing
@testable import AgentCore

/// Owner, 15 November 2026: OneProvider answered 503 "Service temporarily unavailable; retry later"
/// and the reply failed after 4.5 seconds. Then: no waiting minutes for a reply to start, and "it's
/// going to use whatever model I have selected".
@Suite("A chosen AI that's briefly unavailable is asked again until it answers")
struct ProviderDownTests {
    static let unavailable = #"{"error":{"message":"Service temporarily unavailable; retry later","code":503}}"#

    static func environment(_ transport: ScriptedTransport) -> AgentEnvironment {
        var environment = AgentEnvironment(
            openRouter: OpenRouterClient(transport: transport, apiKey: "sk-test"),
            freeRoute: { ModelRouter.route(choice: .free, difficulty: .normal, thinking: .medium, account: AccountState(), catalogue: [:]) },
            onOutOfCredits: {}
        )
        environment.retryDelayScale = 0.001
        return environment
    }

    @Test("It keeps asking the same AI every few seconds, says so, and carries on the moment it answers")
    func keepsAskingTheSameAI() async throws {
        let transport = ScriptedTransport(Array(repeating: .failure(status: 503, body: Self.unavailable), count: 12) + [.events([AgentLoopTests.text("Here it is."), AgentLoopTests.done])])
        var sawNotice = false
        var last: AssistantTurn?
        for await event in AgentLoop.run(AgentTurnInput(chat: AgentLoopTests.newChat("Hi"), route: AgentLoopTests.route(), systemPrompt: "system", tools: []), environment: Self.environment(transport)) {
            guard case .updated(let turn, _) = event else { continue }
            last = turn
            if turn.notices.contains(where: { $0.contains("isn't answering right now") }) { sawNotice = true }
        }
        let turn = try #require(last)
        #expect(turn.status == .done && turn.steps.last?.text == "Here it is.")
        #expect(Set(transport.sentBodies.compactMap { $0["model"]?.stringValue }) == ["test/model"], "never another AI")
        #expect(transport.requestCount == 13)
        #expect(sawNotice)
        #expect(!turn.notices.contains { $0.contains("isn't answering right now") }, "the notice goes once it answers")
    }

    @Test("A model that isn't there (404) still fails quickly")
    func missingModelFailsQuickly() async throws {
        let transport = ScriptedTransport(Array(repeating: .failure(status: 404, body: #"{"error":{"message":"No endpoints found","code":404}}"#), count: 5))
        var last: AssistantTurn?
        for await event in AgentLoop.run(AgentTurnInput(chat: AgentLoopTests.newChat("Hi"), route: AgentLoopTests.route(), systemPrompt: "system", tools: []), environment: Self.environment(transport)) {
            if case .updated(let turn, _) = event { last = turn }
        }
        #expect(last?.status == .failed)
        #expect(transport.requestCount == 3)
    }
}
