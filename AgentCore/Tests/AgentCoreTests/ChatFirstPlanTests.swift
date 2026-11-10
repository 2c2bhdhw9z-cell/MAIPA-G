import Foundation
import Testing
@testable import AgentCore

/// The chat-first plan (6 November 2026): the chat decides, replies that stop early say so and
/// carry on when retried, spend is real or labelled, and slow turns are measured.
@Suite("Chat-first plan")
struct ChatFirstPlanTests {
    // MARK: The chat chooses

    @Test("A plain question never starts a workflow")
    func plainQuestionStaysAnAnswer() {
        #expect(ChatRouting.decide("What does the main file do?") == .answer)
        #expect(ChatRouting.decide("Why does the build crash on launch?") == .answer)
        #expect(ChatRouting.decide("How do I plan this out?") == .answer)
        #expect(ChatRouting.decide("Is there a workflow for this?") == .answer)
        #expect(ChatRouting.decide("Fix the typo in the README please") == .answer)
        #expect(ChatRouting.decide("hi") == .answer)
        #expect(ChatRouting.decide("What does the main file do?").workflowID == nil)
    }

    @Test("A clear 'plan this out' starts the planning workflow")
    func planThisOutStartsAPlan() {
        #expect(ChatRouting.decide("Plan this out: add dark mode to the settings screen") == .plan)
        #expect(ChatRouting.decide("Can you plan this out for the login screen?") == .plan)
        #expect(ChatRouting.decide("Plan this out: add dark mode").workflowID == "look-into-something")
        #expect(BuiltInWorkflows.named("look-into-something") != nil)
    }

    @Test("A clear request for multi-step work starts the full-feature workflow")
    func multiStepStartsFullFeature() {
        #expect(ChatRouting.decide("Build the whole sign-up flow end to end") == .multiStep)
        #expect(ChatRouting.decide("Do all of the auth work step by step") == .multiStep)
        #expect(ChatRouting.decide("Build the whole sign-up flow end to end").workflowID == "full-feature")
        #expect(BuiltInWorkflows.named("full-feature") != nil)
    }

    // MARK: Replies that stop early

    @Test("A reply whose stream ends without a finish says it stopped early")
    func streamEndingWithoutFinishIsMarked() async throws {
        let transport = ScriptedTransport([.events([AgentLoopTests.text("Half a sent")])])
        let (turn, _) = await AgentLoopTests.runToEnd(transport, chat: AgentLoopTests.newChat("Write a poem"), route: AgentLoopTests.route())
        let finished = try #require(turn)
        #expect(finished.stoppedEarly == true)
        #expect(finished.notices.contains(AgentLoop.stoppedEarlyNotice))
        #expect(AgentLoop.stoppedEarlyNotice.hasPrefix("This reply stopped early. Tap retry."))
    }

    @Test("A reply that finishes normally gets no early-stop notice")
    func normalFinishIsNotMarked() async throws {
        let transport = ScriptedTransport([.events([AgentLoopTests.text("Done."), AgentLoopTests.done])])
        let (turn, _) = await AgentLoopTests.runToEnd(transport, chat: AgentLoopTests.newChat("Hi"), route: AgentLoopTests.route())
        let finished = try #require(turn)
        #expect(finished.stoppedEarly == nil)
        #expect(!finished.notices.contains(AgentLoop.stoppedEarlyNotice))
    }

    @Test("Retry after an early stop carries on, and the model is told it was cut off")
    func retryCarriesOnFromTheCut() async throws {
        var step = AssistantStep()
        step.text = "Roses are red, violets"
        step.finishedAt = Date()
        var stopped = AssistantTurn(status: .failed, steps: [step], notices: [AgentLoop.stoppedEarlyNotice])
        stopped.stoppedEarly = true
        var chat = Chat()
        chat.messages = [.user("Write a poem"), ChatMessage(body: .assistant(stopped))]

        let transport = ScriptedTransport([.events([AgentLoopTests.text(" are blue."), AgentLoopTests.done])])
        let environment = AgentEnvironment(
            openRouter: OpenRouterClient(transport: transport, apiKey: "sk-test"),
            freeRoute: { AgentLoopTests.route() },
            onOutOfCredits: {}
        )
        let note = AgentLoop.resumeNote(partialText: step.text)
        var last: AssistantTurn?
        for await event in AgentLoop.run(AgentTurnInput(chat: chat, route: AgentLoopTests.route(), systemPrompt: "system", tools: [], resumeNote: note), environment: environment) {
            if case .updated(let turn, _) = event { last = turn }
        }
        let finished = try #require(last)
        #expect(finished.status == .done)
        // The earlier text is kept; the retry adds to it rather than starting over.
        #expect(finished.steps.count == 2)
        #expect(finished.steps[0].text == "Roses are red, violets")
        #expect(finished.steps[1].text == " are blue.")
        #expect(finished.stoppedEarly == nil)
        #expect(!finished.notices.contains(AgentLoop.stoppedEarlyNotice))
        let body = try #require(transport.sentBodies.first)
        let lastMessage = try #require(body["messages"]?.arrayValue?.last)
        #expect(lastMessage["role"]?.stringValue == "user")
        #expect(lastMessage.jsonString().contains("Retry after an early stop"))
        #expect(lastMessage.jsonString().contains("violets"))
        // "Keep going" is the person's own words; a retry note is not, so the model can tell.
        #expect(!note.contains("Please keep going."))
    }

    // MARK: Slow turns are measured

    @Test("Every model step records where its time went")
    func stepsRecordTiming() async throws {
        let transport = ScriptedTransport([.events([AgentLoopTests.text("Hello"), AgentLoopTests.done])])
        let (turn, _) = await AgentLoopTests.runToEnd(transport, chat: AgentLoopTests.newChat("Hi"), route: AgentLoopTests.route())
        let timing = try #require(turn?.steps.first?.timing)
        #expect(timing.attempts == 1)
        #expect(timing.promptTokens == 10)
        #expect(timing.firstByteSeconds != nil)
        #expect(timing.modelCallSeconds >= 0)
        #expect(timing.sentTokensEstimate > 0)
    }

    @Test("A slow reply's note says where the time went")
    func slowTurnSummaryNamesTheParts() {
        var a = AssistantStep()
        a.timing = StepTiming(firstByteSeconds: 30, modelCallSeconds: 200, longestStallSeconds: 95, retryWaitSeconds: 4, attempts: 2, promptTokens: 182_000, sentTokensEstimate: 150_000, toolSeconds: 40)
        var b = AssistantStep()
        b.timing = StepTiming(firstByteSeconds: 10, modelCallSeconds: 100, attempts: 1, sentTokensEstimate: 1_000, waitingSeconds: 60)
        let text = AgentLoop.slowTurnSummary(elapsed: 404, steps: [a, b][...])
        #expect(text.hasPrefix("Slow reply (6m 44s)"))
        #expect(text.contains("2 model calls took 5m 0s"))
        #expect(text.contains("longest silence mid-reply 1m 35s"))
        #expect(text.contains("Tools 40s"))
        #expect(text.contains("Waiting on sub-agents 1m 0s"))
        #expect(text.contains("Retry waits 4s over 3 requests"))
        #expect(text.contains("Largest prompt 182000 tokens"))
    }

    // MARK: Real spend

    @Test("A turn's real cost is the balance before minus the balance after")
    func realCostFromBalances() {
        var turn = AssistantTurn(status: .done)
        #expect(turn.realCost == nil)
        turn.balanceBefore = 78.12
        #expect(turn.realCost == nil)
        turn.balanceAfter = 77.72
        #expect(abs((turn.realCost ?? 0) - 0.40) < 0.000_001)
        // A top-up during the turn is never shown as negative spend.
        turn.balanceAfter = 90
        #expect(turn.realCost == 0)
    }

    @Test("The chat's headline is real where measured and labelled where estimated")
    func spendSummaryLabels() {
        var real = AssistantTurn(status: .done)
        real.balanceBefore = 10
        real.balanceAfter = 9.5
        var estimatedStep = AssistantStep()
        estimatedStep.usage = Usage(promptTokens: 100, completionTokens: 10, cost: 0.25, costIsEstimate: true)
        let estimated = AssistantTurn(status: .done, steps: [estimatedStep])
        var unknownStep = AssistantStep()
        unknownStep.usage = Usage(promptTokens: 100, completionTokens: 10, priceUnknown: true)
        let unknown = AssistantTurn(status: .done, steps: [unknownStep])

        var chat = Chat()
        chat.messages = [.user("a"), ChatMessage(body: .assistant(real))]
        #expect(chat.spendSummary == SpendSummary(dollars: 0.5, realTurns: 1))

        chat.messages += [.user("b"), ChatMessage(body: .assistant(estimated)), .user("c"), ChatMessage(body: .assistant(unknown))]
        let summary = chat.spendSummary
        #expect(abs((summary.dollars ?? 0) - 0.75) < 0.000_001)
        #expect(summary.hasEstimate)
        #expect(summary.hasUnknownPrice)
    }

    @Test("A model with no known price is unknown, never $0, and a computed cost is an estimate")
    func gatewayCostIsHonest() {
        let endpoint = AIProviderEndpoint(id: "custom", name: "Custom", baseURL: "https://example.com/v1", apiKey: "k", isEnabled: true)
        let noPrice = AIProviderGateway.withFallbackCost(Usage(promptTokens: 1_000, completionTokens: 100), rawModelID: "paid-model", endpoint: endpoint, catalogueModel: nil)
        #expect(noPrice.cost == nil)
        #expect(noPrice.priceUnknown == true)
        let reportedZero = AIProviderGateway.withFallbackCost(Usage(promptTokens: 1_000, completionTokens: 100, cost: 0), rawModelID: "paid-model", endpoint: endpoint, catalogueModel: nil)
        #expect(reportedZero.cost == nil)
        #expect(reportedZero.priceUnknown == true)
        let reported = AIProviderGateway.withFallbackCost(Usage(promptTokens: 1_000, completionTokens: 100, cost: 0.02), rawModelID: "paid-model", endpoint: endpoint, catalogueModel: nil)
        #expect(reported.cost == 0.02)
        #expect(reported.costIsEstimate == nil)
        #expect(reported.priceUnknown == nil)
    }

    @Test("Adding usage keeps the estimate and unknown-price marks")
    func usageSumKeepsMarks() {
        let total = Usage(cost: 0.1) + Usage(cost: 0.2, costIsEstimate: true) + Usage(priceUnknown: true)
        #expect(total.costIsEstimate == true)
        #expect(total.priceUnknown == true)
        #expect(Usage(cost: 0.1) + Usage(cost: 0.2) == Usage(cost: 0.1 + 0.2))
    }
}
