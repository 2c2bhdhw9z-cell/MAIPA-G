import Foundation
import Testing
@testable import AgentCore

/// Plays back scripted OpenRouter replies and records what was sent.
final class ScriptedTransport: HTTPTransport, @unchecked Sendable {
    enum Reply {
        case events([String])
        case failure(status: Int, body: String)
    }

    private let lock = NSLock()
    private var replies: [Reply]
    private(set) var sentBodies: [JSONValue] = []

    init(_ replies: [Reply]) {
        self.replies = replies
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        HTTPResponse(status: 404)
    }

    func stream(_ request: HTTPRequest) async throws -> HTTPStreamResponse {
        let reply: Reply = lock.withLock {
            sentBodies.append(request.body.flatMap(JSONValue.parse) ?? .null)
            return replies.isEmpty ? .failure(status: 500, body: "no more replies") : replies.removeFirst()
        }
        switch reply {
        case .failure(let status, let body):
            return HTTPStreamResponse(status: status, headers: [:], body: AsyncThrowingStream { $0.yield(Data(body.utf8)); $0.finish() })
        case .events(let events):
            let text = events.map { "data: \($0)\n\n" }.joined() + "data: [DONE]\n\n"
            return HTTPStreamResponse(status: 200, headers: ["content-type": "text/event-stream"], body: AsyncThrowingStream { continuation in
                // Split into small pieces to exercise the parser.
                let bytes = Array(text.utf8)
                stride(from: 0, to: bytes.count, by: 23).forEach { continuation.yield(Data(bytes[$0..<min($0 + 23, bytes.count)])) }
                continuation.finish()
            })
        }
    }

    var requestCount: Int { lock.withLock { sentBodies.count } }
}

struct EchoTool: AgentTool {
    let name = "read_file"
    var spec: ToolSpec { ToolSpec(name: name, description: "Read", parameters: ["type": "object"]) }
    func runningSummary(for arguments: JSONValue) -> String { "Reading \(arguments["path"]?.stringValue ?? "")…" }
    func run(arguments: JSONValue, progress: @escaping @Sendable (String) -> Void) async throws -> ToolOutput {
        progress("Halfway there")
        let path = try arguments.requiredString("path")
        if path == "missing.txt" { throw ToolInputError("There is no file missing.txt.") }
        return ToolOutput(forModel: "contents of \(path)", summary: "Read \(path)")
    }
}

@Suite("Agent loop")
struct AgentLoopTests {
    static func text(_ content: String, model: String = "test/model") -> String {
        #"{"id":"g","model":"\#(model)","choices":[{"index":0,"delta":{"content":\#(JSONValue.string(content).jsonString())}}]}"#
    }

    static func toolCall(id: String, name: String, arguments: String, index: Int = 0) -> String {
        #"{"id":"g","model":"test/model","choices":[{"index":0,"delta":{"tool_calls":[{"index":\#(index),"id":"\#(id)","type":"function","function":{"name":"\#(name)","arguments":\#(JSONValue.string(arguments).jsonString())}}]}}]}"#
    }

    static let done = #"{"id":"g","choices":[{"index":0,"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":10,"completion_tokens":5,"cost":0.001}}"#
    static let toolsDone = #"{"id":"g","choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":10,"completion_tokens":5,"cost":0.002}}"#

    static func route(auto: Bool = false) -> Route {
        ModelRouter.route(choice: auto ? .auto : .model("test/model"), difficulty: .normal, thinking: .medium, account: AccountState(), catalogue: [:])
    }

    static func runToEnd(_ transport: ScriptedTransport, chat: Chat, route: Route, tools: [any AgentTool] = [EchoTool()]) async -> (AssistantTurn?, [AssistantTurn]) {
        let environment = AgentEnvironment(
            openRouter: OpenRouterClient(transport: transport, apiKey: "sk-test"),
            freeRoute: { ModelRouter.route(choice: .free, difficulty: .normal, thinking: .medium, account: AccountState(), catalogue: [:]) },
            onOutOfCredits: {}
        )
        var last: AssistantTurn?
        var milestones: [AssistantTurn] = []
        for await event in AgentLoop.run(AgentTurnInput(chat: chat, route: route, systemPrompt: "system", tools: tools), environment: environment) {
            if case .updated(let turn, let milestone) = event {
                last = turn
                if milestone { milestones.append(turn) }
            }
        }
        return (last, milestones)
    }

    static func newChat(_ text: String) -> Chat {
        var chat = Chat()
        chat.messages = [.user(text), ChatMessage(body: .assistant(AssistantTurn()))]
        return chat
    }

    @Test func plainAnswer() async throws {
        let transport = ScriptedTransport([.events([Self.text("Hello "), Self.text("there."), Self.done])])
        let (turn, _) = await Self.runToEnd(transport, chat: Self.newChat("Hi"), route: Self.route())
        let finished = try #require(turn)
        #expect(finished.status == .done)
        #expect(finished.steps.count == 1)
        #expect(finished.steps[0].text == "Hello there.")
        #expect(finished.steps[0].model == "test/model")
        #expect(finished.usage.cost == 0.001)
        let body = try #require(transport.sentBodies.first)
        #expect(body["messages"]?.arrayValue?.map { $0["role"]?.stringValue ?? "" } == ["system", "user"])
        #expect(body["tools"]?.arrayValue?.count == 2) // read_file and ask_user
    }

    @Test func toolCallsRunAndResultsGoBack() async throws {
        let transport = ScriptedTransport([
            .events([Self.text("Let me look."), Self.toolCall(id: "c1", name: "read_file", arguments: #"{"path":"README.md"}"#), Self.toolCall(id: "c2", name: "read_file", arguments: #"{"path":"missing.txt"}"#, index: 1), Self.toolsDone]),
            .events([Self.text("It says hello."), Self.done]),
        ])
        let (turn, milestones) = await Self.runToEnd(transport, chat: Self.newChat("What's in the readme?"), route: Self.route())
        let finished = try #require(turn)
        #expect(finished.status == .done)
        #expect(finished.steps.count == 2)
        let calls = finished.steps[0].toolCalls
        #expect(calls.map(\.status) == [.done, .failed])
        #expect(calls[0].summary == "Read README.md")
        #expect(calls[1].result == "Error: There is no file missing.txt.")
        #expect(finished.steps[1].text == "It says hello.")
        #expect(milestones.contains { $0.steps.first?.toolCalls.first?.status == .running })

        let second = try #require(transport.sentBodies.last?["messages"]?.arrayValue)
        #expect(second.map { $0["role"]?.stringValue ?? "" } == ["system", "user", "assistant", "tool", "tool"])
        #expect(second[2]["tool_calls"]?.arrayValue?.count == 2)
        #expect(second[3]["content"] == "contents of README.md")
        #expect(second[3]["tool_call_id"] == "c1")
    }

    @Test func questionsPauseAndAnswersResume() async throws {
        let ask = #"{"questions":[{"question":"Which branch?","options":["main","dev"]}]}"#
        let transport = ScriptedTransport([
            .events([Self.toolCall(id: "q1", name: "ask_user", arguments: ask), Self.toolsDone]),
            .events([Self.text("Using dev."), Self.done]),
        ])
        let first = await Self.runToEnd(transport, chat: Self.newChat("Look at the code"), route: Self.route())
        let paused = try #require(first.0)
        #expect(paused.status == .waitingForUser)
        #expect(paused.pendingQuestions?.questions.questions.first?.options == ["main", "dev"])
        #expect(transport.requestCount == 1)

        var chat = Self.newChat("Look at the code")
        var answered = paused
        answered.steps[0].toolCalls[0].questions?.answers = ["dev"]
        chat.messages[1].assistantTurn = answered
        let second = await Self.runToEnd(transport, chat: chat, route: Self.route())
        let finished = try #require(second.0)
        #expect(finished.status == .done)
        #expect(finished.steps.last?.text == "Using dev.")
        let messages = try #require(transport.sentBodies.last?["messages"]?.arrayValue)
        #expect(messages.last?["content"]?.stringValue?.contains("Answer: dev") == true)
    }

    @Test func autoSwitchesToFreeWhenCreditRunsOut() async throws {
        let transport = ScriptedTransport([
            .failure(status: 402, body: #"{"error":{"code":402,"message":"Insufficient credits","metadata":{"limit_source":"openrouter_credits"}}}"#),
            .events([Self.text("Free answer.", model: "free/model:free"), Self.done]),
        ])
        let (turn, _) = await Self.runToEnd(transport, chat: Self.newChat("Hi"), route: Self.route(auto: true))
        let finished = try #require(turn)
        #expect(finished.status == .done)
        #expect(finished.notices.contains { $0.contains("free AIs") })
        #expect(finished.routeLabel == "Auto · free AIs")
        #expect(transport.sentBodies.first?["model"] == "openrouter/auto")
        #expect(transport.sentBodies.first?["plugins"] == [["id": "auto-router", "cost_tier": "medium"]])
        #expect(transport.sentBodies.last?["model"] == "openrouter/free")
    }

    @Test func paidModelOutOfCreditFailsWithChoice() async throws {
        let transport = ScriptedTransport([
            .failure(status: 402, body: #"{"error":{"code":402,"message":"Insufficient credits"}}"#),
        ])
        let (turn, _) = await Self.runToEnd(transport, chat: Self.newChat("Hi"), route: Self.route())
        let finished = try #require(turn)
        #expect(finished.status == .failed)
        #expect(finished.failure?.kind == .outOfCredits)
        #expect(finished.steps.isEmpty)
    }

    @Test func spendLimitPausesAndCanBeRaised() async throws {
        // Each step costs $0.60 (see toolsDone); the limit is $1.
        let call = { (id: String) in Self.toolCall(id: id, name: "read_file", arguments: #"{"path":"a"}"#) }
        let costly = #"{"id":"g","choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":10,"completion_tokens":5,"cost":0.6}}"#
        let transport = ScriptedTransport([
            .events([call("c1"), costly]),
            .events([call("c2"), costly]),
            .events([Self.text("Done."), Self.done]),
        ])
        let environment = AgentEnvironment(
            openRouter: OpenRouterClient(transport: transport, apiKey: "sk"),
            freeRoute: { ModelRouter.route(choice: .free, difficulty: .normal, thinking: .medium, account: AccountState(), catalogue: [:]) },
            onOutOfCredits: {}
        )
        var paused: AssistantTurn?
        for await event in AgentLoop.run(AgentTurnInput(chat: Self.newChat("go"), route: Self.route(), systemPrompt: "s", tools: [EchoTool()], spendLimit: 1), environment: environment) {
            if case .updated(let turn, _) = event { paused = turn }
        }
        let first = try #require(paused)
        #expect(first.status == .waitingForUser)
        #expect(first.spendCheck == 1.2)
        #expect(first.pendingQuestions == nil)
        #expect(transport.requestCount == 2)

        // "Keep going": allow another dollar.
        var chat = Self.newChat("go")
        var approved = first
        approved.approvedSpendUpTo = 1.2 + 1
        chat.messages[1].assistantTurn = approved
        var finished: AssistantTurn?
        for await event in AgentLoop.run(AgentTurnInput(chat: chat, route: Self.route(), systemPrompt: "s", tools: [EchoTool()], spendLimit: 1), environment: environment) {
            if case .updated(let turn, _) = event { finished = turn }
        }
        #expect(finished?.status == .done)
        #expect(finished?.spendCheck == nil)
        #expect(finished?.steps.last?.text == "Done.")
    }

    @Test func stoppingKeepsWhatWasWrittenAndSendsAFinalState() async throws {
        /// Streams a few words, then waits until cancelled.
        final class SlowTransport: HTTPTransport, @unchecked Sendable {
            func send(_ request: HTTPRequest) async throws -> HTTPResponse { HTTPResponse(status: 404) }
            func stream(_ request: HTTPRequest) async throws -> HTTPStreamResponse {
                let first = Data("data: \(AgentLoopTests.text("Partial answer"))\n\n".utf8)
                return HTTPStreamResponse(status: 200, headers: [:], body: AsyncThrowingStream { continuation in
                    continuation.yield(first)
                    let waiter = Task {
                        try? await Task.sleep(nanoseconds: 30_000_000_000)
                        continuation.finish()
                    }
                    continuation.onTermination = { _ in waiter.cancel() }
                })
            }
        }
        let environment = AgentEnvironment(
            openRouter: OpenRouterClient(transport: SlowTransport(), apiKey: "sk"),
            freeRoute: { ModelRouter.route(choice: .free, difficulty: .normal, thinking: .medium, account: AccountState(), catalogue: [:]) },
            onOutOfCredits: {}
        )
        let run = AgentLoop.start(AgentTurnInput(chat: Self.newChat("hi"), route: Self.route(), systemPrompt: "s", tools: []), environment: environment)
        var last: AssistantTurn?
        for await event in run.events {
            guard case .updated(let turn, _) = event else { continue }
            last = turn
            if turn.steps.first?.text == "Partial answer", turn.status == .running { run.cancel() }
        }
        let stopped = try #require(last)
        #expect(stopped.status == .stopped)
        #expect(stopped.steps.first?.text == "Partial answer")
        #expect(stopped.steps.first?.finishedAt != nil)
    }

    @Test func noToolsForModelsThatCantUseThem() async throws {
        let transport = ScriptedTransport([.events([Self.text("Hi."), Self.done])])
        let environment = AgentEnvironment(
            openRouter: OpenRouterClient(transport: transport, apiKey: "sk"),
            freeRoute: { ModelRouter.route(choice: .free, difficulty: .normal, thinking: .medium, account: AccountState(), catalogue: [:]) },
            onOutOfCredits: {}
        )
        for await _ in AgentLoop.run(AgentTurnInput(chat: Self.newChat("hi"), route: Self.route(), systemPrompt: "s", tools: [EchoTool()], allowTools: false), environment: environment) {}
        #expect(transport.sentBodies.first?["tools"] == nil)
    }

    @Test func transcriptAlwaysAnswersEveryToolCall() {
        var chat = Chat()
        var step = AssistantStep()
        step.text = "Looking"
        step.toolCalls = [ToolCallRecord(id: "a", name: "read_file", arguments: "{}", summary: "Reading…")]
        chat.messages = [.user("one"), ChatMessage(body: .assistant(AssistantTurn(status: .stopped, steps: [step]))), .user("two")]
        let messages = Transcript.messages(for: chat, systemPrompt: "s")
        #expect(messages.map(\.role) == [.system, .user, .assistant, .tool, .user])
        #expect(messages[3].content == Transcript.interruptedToolResult)
    }

    @Test func fittingDropsOldToolOutputFirst() {
        var messages: [APIMessage] = [.system("s"), .user("first")]
        messages.append(APIMessage(role: .assistant, content: nil, toolCalls: [APIToolCall(id: "x", name: "read_file", arguments: "{}")]))
        messages.append(.tool(id: "x", String(repeating: "a", count: 40_000)))
        messages.append(APIMessage(role: .assistant, content: "ok"))
        messages.append(.user("latest question"))
        let (fitted, trimmed) = Transcript.fit(messages, budget: 2_000)
        #expect(trimmed)
        #expect(fitted.count == messages.count)
        #expect(fitted[3].content == Transcript.trimmedToolResult)
        #expect(fitted.last?.content == "latest question")
    }

    @Test func routerFollowsMoneyAndDifficulty() {
        let catalogue: [String: ModelInfo] = [:]
        let paid = ModelRouter.route(choice: .auto, difficulty: .hard, thinking: .medium, account: AccountState(isFreeTier: false), catalogue: catalogue)
        #expect(paid.model == "openrouter/auto" && paid.plugins == [["id": "auto-router", "cost_tier": "high"]] && !paid.isFree)
        let broke = ModelRouter.route(choice: .auto, difficulty: .hard, thinking: .medium, account: AccountState(isFreeTier: true), catalogue: catalogue)
        #expect(broke.model == "openrouter/free" && broke.isFree && broke.isAuto)
        let recent = ModelRouter.route(choice: .auto, difficulty: .quick, thinking: .medium, account: AccountState(outOfCreditsAt: Date().addingTimeInterval(-60)), catalogue: catalogue)
        #expect(recent.isFree)
        let later = ModelRouter.route(choice: .auto, difficulty: .quick, thinking: .medium, account: AccountState(outOfCreditsAt: Date().addingTimeInterval(-7200)), catalogue: catalogue)
        #expect(!later.isFree && later.plugins == [["id": "auto-router", "cost_tier": "low"]])
        #expect(TaskDifficulty.estimate("hi!", hasRepo: false) == .quick)
        #expect(TaskDifficulty.estimate("Why does the build crash on launch?", hasRepo: true) == .hard)
        #expect(TaskDifficulty.estimate("What does the main file do?", hasRepo: true) == .normal)
    }
}
