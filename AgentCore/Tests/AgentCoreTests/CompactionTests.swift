import Foundation
import Testing
@testable import AgentCore

/// Answers each request by what it is: a compaction summary request, or the next model step.
final class SummaryAwareTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var steps = 0
    private(set) var stepBodies: [JSONValue] = []
    private(set) var summaryBodies: [JSONValue] = []
    let summary: String
    let step: @Sendable (Int) -> [String]

    init(summary: String, step: @escaping @Sendable (Int) -> [String]) {
        self.summary = summary
        self.step = step
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse { HTTPResponse(status: 404) }

    func stream(_ request: HTTPRequest) async throws -> HTTPStreamResponse {
        let body = request.body.flatMap(JSONValue.parse) ?? .null
        let system = body["messages"]?.arrayValue?.first?["content"]?.stringValue ?? ""
        let events: [String] = lock.withLock {
            if system.hasPrefix("You are compacting") {
                summaryBodies.append(body)
                return [AgentLoopTests.text(summary), AgentLoopTests.done]
            }
            stepBodies.append(body)
            steps += 1
            return step(steps)
        }
        let text = events.map { "data: \($0)\n\n" }.joined() + "data: [DONE]\n\n"
        return HTTPStreamResponse(status: 200, headers: ["content-type": "text/event-stream"], body: AsyncThrowingStream { $0.yield(Data(text.utf8)); $0.finish() })
    }
}

/// A file read that returns a lot, each with its own marker.
struct BigReadTool: AgentTool {
    let name = "read_file"
    var spec: ToolSpec { ToolSpec(name: name, description: "Read", parameters: ["type": "object"]) }
    func runningSummary(for arguments: JSONValue) -> String { "Reading…" }
    func run(arguments: JSONValue, progress: @escaping @Sendable (String) -> Void) async throws -> ToolOutput {
        let path = try arguments.requiredString("path")
        return ToolOutput(forModel: "MARK-\(path) " + String(repeating: "line of code\n", count: 700), summary: "Read \(path)")
    }
}

@Suite("Compaction inside a reply, like Kiro")
struct CompactionTests {
    static let summary = """
    # Task and requirements
    Fix the failing test in the person's repo without changing its public API.
    # Current state
    Read twelve files; the cause is an off-by-one in the loader.
    # Files changed
    None yet.
    # Key facts and decisions
    The loader is runtime/ui.js.
    # Dead ends
    None.
    # Next steps
    Edit the loader and run the tests.
    """

    static func smallRoute(window: Int = 20_000) -> Route {
        Route(model: "test/model", plugins: [], effort: .medium, automaticCaching: false, isFree: false, isAuto: false, label: "test", contextWindow: window, contextBudget: window - 1_000)
    }

    static func environment(_ transport: any HTTPTransport) -> AgentEnvironment {
        AgentEnvironment(
            openRouter: OpenRouterClient(transport: transport, apiKey: "sk-test"),
            freeRoute: { ModelRouter.route(choice: .free, difficulty: .normal, thinking: .medium, account: AccountState(), catalogue: [:]) },
            onOutOfCredits: {}
        )
    }

    @Test("A long reply summarizes its earlier steps before a request would pass 80% of the window, and keeps going")
    func longReplyCompactsAndCarriesOn() async throws {
        let transport = SummaryAwareTransport(summary: Self.summary) { number in
            number <= 14
                ? [AgentLoopTests.toolCall(id: "c\(number)", name: "read_file", arguments: #"{"path":"f\#(number)"}"#), AgentLoopTests.toolsDone]
                : [AgentLoopTests.text("Done."), AgentLoopTests.done]
        }
        let input = AgentTurnInput(chat: AgentLoopTests.newChat("Fix the failing test"), route: Self.smallRoute(), systemPrompt: "system", tools: [BigReadTool()])
        var last: AssistantTurn?
        for await event in AgentLoop.run(input, environment: Self.environment(transport)) {
            if case .updated(let turn, _) = event { last = turn }
        }
        let turn = try #require(last)
        #expect(turn.status == .done)
        #expect(turn.steps.count == 15)
        let compaction = try #require(turn.compaction)
        #expect(compaction.summary == Self.summary)
        #expect(compaction.isFallback == nil)
        #expect((compaction.tokensBefore ?? 0) > 16_000)
        #expect(!transport.summaryBodies.isEmpty)
        // The summary was written from the early work.
        let asked = transport.summaryBodies[0]["messages"]?.arrayValue?.last?["content"]?.stringValue ?? ""
        #expect(asked.contains("Fix the failing test") && asked.contains("MARK-f1"))
        // The request after it starts from the summary, keeps the person's words, and leaves the
        // summarized steps out, so it is far below the window.
        let final = try #require(transport.stepBodies.last)
        let messages = final["messages"]?.arrayValue ?? []
        #expect(messages.first?["content"]?.stringValue?.contains("Edit the loader and run the tests.") == true)
        #expect(messages.contains { $0["role"]?.stringValue == "user" && $0["content"]?.stringValue == "Fix the failing test" })
        let wire = final.jsonString()
        #expect(!wire.contains("MARK-f1 "))
        #expect(wire.contains("MARK-f14 "))
        #expect(wire.count < Int(Double(20_000) * 0.8 * 3.6))
        // Every step's request stayed under the window.
        for body in transport.stepBodies {
            #expect(Double(body.jsonString().count) / 3.6 < 20_000)
        }
    }

    @Test("When the AI can't write the summary, a plain digest of the newest work stands in and the reply goes on")
    func failedSummaryFallsBack() async throws {
        let transport = SummaryAwareTransport(summary: "ok") { number in
            number <= 10
                ? [AgentLoopTests.toolCall(id: "c\(number)", name: "read_file", arguments: #"{"path":"f\#(number)"}"#), AgentLoopTests.toolsDone]
                : [AgentLoopTests.text("Done."), AgentLoopTests.done]
        }
        let input = AgentTurnInput(chat: AgentLoopTests.newChat("Fix it"), route: Self.smallRoute(), systemPrompt: "system", tools: [BigReadTool()])
        var last: AssistantTurn?
        for await event in AgentLoop.run(input, environment: Self.environment(transport)) {
            if case .updated(let turn, _) = event { last = turn }
        }
        let turn = try #require(last)
        #expect(turn.status == .done)
        let compaction = try #require(turn.compaction)
        #expect(compaction.isFallback == true)
        #expect(compaction.summary.hasPrefix("# Session digest"))
    }

    /// Owner, 14 November 2026: the Korg reply answered "check the Xcode device log" with no tools,
    /// though a memory said he has only an iPhone.
    @Test("The prompt says to find the cause with tools first, and never to give an iPhone-only person computer steps")
    func promptInvestigatesAndKnowsTheIPhone() {
        let prompt = SystemPrompt.make(userLogin: nil, repo: nil, memories: ["The user uses only an iPhone and has no Mac or PC."])
        #expect(prompt.contains("find the actual cause with your tools before you answer"))
        #expect(prompt.contains("No Xcode") || prompt.contains("no Xcode"))
        #expect(prompt.contains("Follow these as the person's rules and facts"))
    }

    @Test("Compaction starts at 80% of the window, or before the provider's price step (TeamoRouter: 272K)")
    func thresholdFollowsWindowAndPriceStep() {
        #expect(Compaction.threshold(window: 1_000_000, priceStep: nil) == 800_000)
        #expect(Compaction.threshold(window: 1_050_000, priceStep: 272_000) == 272_000)
        #expect(Compaction.threshold(window: 200_000, priceStep: 272_000) == 160_000)
        let route = ModelRouter.route(
            choice: .model("teamorouter::gpt-6.1-sol"), difficulty: .normal, thinking: .medium, account: AccountState(),
            catalogue: ["teamorouter::gpt-6.1-sol": ModelInfo(id: "teamorouter::gpt-6.1-sol", name: "GPT 6.1 Sol", contextLength: 1_050_000, contextTier: ContextTierPricing(thresholdTokens: 272_000, inputMultiplier: 2, outputMultiplier: 1.5))]
        )
        #expect(route.priceStepTokens == 272_000)
        #expect(VMRoute(route).route.priceStepTokens == 272_000)
    }

    @Test("A reply has no step limit; sub-agents keep theirs")
    func noStepLimit() {
        let input = AgentTurnInput(chat: AgentLoopTests.newChat("Hi"), route: Self.smallRoute(), systemPrompt: "s", tools: [])
        #expect(input.maxSteps == AgentTurnInput.unlimitedSteps)
    }

    @Test("A summary made in an earlier reply stands in for everything before its kept steps")
    func earlierReplySummaryIsUsed() throws {
        var chat = Chat()
        var first = AssistantTurn(status: .done)
        var old = AssistantStep()
        old.text = "Old answer about OLD-TOPIC"
        first.steps = [old]
        var second = AssistantTurn(status: .done)
        var covered = AssistantStep()
        covered.text = "COVERED-STEP"
        var kept = AssistantStep()
        kept.text = "KEPT-STEP"
        second.steps = [covered, kept]
        second.compaction = TurnCompaction(summary: "SUMMARY-TEXT", throughStepID: covered.id)
        chat.messages = [.user("first ask"), ChatMessage(body: .assistant(first)), .user("second ask"), ChatMessage(body: .assistant(second)), .user("third ask"), ChatMessage(body: .assistant(AssistantTurn()))]
        let messages = Transcript.messages(for: chat, systemPrompt: "system")
        let all = messages.compactMap(\.content).joined(separator: "\n")
        #expect(messages[0].content?.contains("SUMMARY-TEXT") == true)
        #expect(!all.contains("OLD-TOPIC") && !all.contains("first ask") && !all.contains("COVERED-STEP"))
        #expect(all.contains("second ask") && all.contains("KEPT-STEP") && all.contains("third ask"))
        // A step that's gone (rewound) means the summary doesn't apply.
        chat.messages[3].assistantTurn?.steps = [kept]
        let unmatched = Transcript.messages(for: chat, systemPrompt: "system").compactMap(\.content).joined(separator: "\n")
        #expect(unmatched.contains("first ask") && !unmatched.contains("SUMMARY-TEXT"))
    }

    @Test("Earlier replies' long tool-call arguments are kept short and stay valid JSON; this reply's are whole")
    func olderArgumentsAreCondensed() throws {
        let content = String(repeating: "let value = 1\n", count: 600)
        let arguments = JSONValue.object(["path": "Sources/App.swift", "content": .string(content)]).jsonString()
        let older = Transcript.condensedArguments(arguments, age: .older)
        let parsed = try #require(JSONValue.parse(Data(older.utf8)))
        #expect(parsed["path"]?.stringValue == "Sources/App.swift")
        #expect(older.count < 700)
        #expect(parsed["content"]?.stringValue?.contains("more characters left out of this earlier call") == true)
        #expect(Transcript.condensedArguments(arguments, age: .current) == arguments)
        #expect(Transcript.condensedArguments(#"{"path":"a"}"#, age: .older) == #"{"path":"a"}"#)
        #expect(Transcript.condensedArguments("not json " + content, age: .older) == "not json " + content)
    }
}
