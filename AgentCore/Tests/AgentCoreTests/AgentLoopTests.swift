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

actor ApprovalCounter {
    var runs = 0
    func increment() { runs += 1 }
}

struct ApprovalTool: AgentTool {
    let counter: ApprovalCounter
    var allowLabel = "Allow"
    let name = "delete_file"
    var spec: ToolSpec { ToolSpec(name: name, description: "Delete", parameters: ["type": "object"]) }
    func runningSummary(for arguments: JSONValue) -> String { "Deleting file…" }
    func approvalRequest(for arguments: JSONValue) async -> ToolApprovalRequest? { ToolApprovalRequest(question: "Delete file?", allowLabel: allowLabel) }
    func run(arguments: JSONValue, progress: @escaping @Sendable (String) -> Void) async throws -> ToolOutput {
        await counter.increment()
        return ToolOutput(forModel: "deleted", summary: "Deleted file")
    }
}

actor WorkflowTestRecorder {
    var calls: [String] = []
    var checkpoints: [WorkflowCheckpoint] = []
    var goalOnCall: Int?

    init(goalOnCall: Int? = nil) { self.goalOnCall = goalOnCall }

    func run(_ invocation: AgentInvocation) async throws -> AgentExecutionResult {
        calls.append(invocation.task)
        let number = calls.count
        if invocation.task.contains("slow") { try await Task.sleep(nanoseconds: 40_000_000) }
        return AgentExecutionResult(output: "result \(invocation.task)", model: invocation.definition.modelPolicy == .differentFromPrimary ? "other/model" : "main/model", goalMet: goalOnCall == number, cost: 0.01)
    }

    func save(_ checkpoint: WorkflowCheckpoint) { checkpoints.append(checkpoint) }
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

    @Test func destructiveToolsPauseForRealApproval() async throws {
        let counter = ApprovalCounter()
        let transport = ScriptedTransport([
            .events([Self.toolCall(id: "d1", name: "delete_file", arguments: #"{"path":"old.txt"}"#), Self.toolsDone]),
            .events([Self.text("Done."), Self.done]),
        ])
        let first = await Self.runToEnd(transport, chat: Self.newChat("delete old.txt"), route: Self.route(), tools: [ApprovalTool(counter: counter)])
        var paused = try #require(first.0)
        #expect(paused.status == .waitingForUser)
        #expect(await counter.runs == 0)
        #expect(paused.pendingQuestions?.questions.questions.first?.text == "Delete file?")

        paused.steps[0].toolCalls[0].questions?.answers = ["Allow"]
        var chat = Self.newChat("delete old.txt")
        chat.messages[1].assistantTurn = paused
        let second = await Self.runToEnd(transport, chat: chat, route: Self.route(), tools: [ApprovalTool(counter: counter)])
        #expect(second.0?.status == .done)
        #expect(await counter.runs == 1)

        let labeledCounter = ApprovalCounter()
        let labeledTransport = ScriptedTransport([
            .events([Self.toolCall(id: "d2", name: "delete_file", arguments: #"{"path":"picture.png"}"#), Self.toolsDone]),
            .events([Self.text("Generated."), Self.done]),
        ])
        let labeledFirst = await Self.runToEnd(labeledTransport, chat: Self.newChat("make a picture"), route: Self.route(), tools: [ApprovalTool(counter: labeledCounter, allowLabel: "Generate")])
        var labeledPause = try #require(labeledFirst.0)
        #expect(labeledPause.pendingQuestions?.questions.questions.first?.options == ["Generate", "Don't allow"])
        labeledPause.steps[0].toolCalls[0].questions?.answers = ["Generate"]
        var labeledChat = Self.newChat("make a picture")
        labeledChat.messages[1].assistantTurn = labeledPause
        let labeledSecond = await Self.runToEnd(labeledTransport, chat: labeledChat, route: Self.route(), tools: [ApprovalTool(counter: labeledCounter, allowLabel: "Generate")])
        #expect(labeledSecond.0?.status == .done)
        #expect(await labeledCounter.runs == 1)
    }

    @Test func webParserAndSafetyRejectPrivateAddresses() {
        let html = #"<a class="result__a" href="https://example.com/page">Example result</a><div class="result__snippet">Useful words</div>"#
        let result = FreeWebSearch.parse(html)
        #expect(result.first?.url.absoluteString == "https://example.com/page")
        #expect(result.first?.title == "Example result")
        #expect(!WebPageReader.isSafe(URL(string: "http://127.0.0.1/private")!))
        #expect(WebPageReader.isSafe(URL(string: "https://example.com")!))
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

    @Test func aiMemoryToolsPersistAndShowANotice() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("maipag-memory-tool-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProductStore<MemoryRecord>(dataDirectory: root, folder: "memories")
        let transport = ScriptedTransport([
            .events([Self.toolCall(id: "m1", name: "add_memory", arguments: #"{"text":"Keep replies short"}"#), Self.toolsDone]),
            .events([Self.text("I'll remember that."), Self.done]),
        ])
        let result = await Self.runToEnd(transport, chat: Self.newChat("Remember short replies"), route: Self.route(), tools: [AddMemoryTool(store: store), EditMemoryTool(store: store)])
        let turn = try #require(result.0)
        let saved = try #require(await store.loadAll().first)
        #expect(saved.text == "Keep replies short" && saved.source == .ai)
        #expect(turn.notices.contains { $0 == "Saved a memory: Keep replies short" })
        #expect(turn.steps[0].toolCalls[0].summary == "Saved a memory")

        _ = try await AddMemoryTool(store: store).run(arguments: ["text": "Keep replies short"], progress: { _ in })
        #expect(await store.loadAll().count == 1, "adding the same memory is idempotent")
        let prompt = SystemPrompt.make(userLogin: nil, repo: nil, memories: ["Keep replies short"])
        #expect(prompt.contains("Memories the person chose"))
        #expect(prompt.contains("- Keep replies short"))
    }

    @Test func reportOnlyAgentCannotReceiveChangingTools() async throws {
        let transport = ScriptedTransport([.events([Self.text("Checked."), Self.done])])
        let agent = try #require(BuiltInAgents.named("investigator"))
        let environment = AgentEnvironment(
            openRouter: OpenRouterClient(transport: transport, apiKey: "sk"),
            freeRoute: { Self.route() }, onOutOfCredits: {}
        )
        let input = AgentTurnInput(chat: Self.newChat("check"), route: Self.route(), systemPrompt: "s", tools: [EchoTool(), ApprovalTool(counter: ApprovalCounter())], agent: agent)
        for await _ in AgentLoop.run(input, environment: environment) {}
        let names = transport.sentBodies.first?["tools"]?.arrayValue?.compactMap { $0["function"]?["name"]?.stringValue }
        #expect(names == ["read_file", "ask_user"])
    }

    @Test func helperFanOutJoinsInDeclarationOrderAndUsesDifferentModel() async throws {
        let recorder = WorkflowTestRecorder()
        let executor = AgentExecutor { invocation in try await recorder.run(invocation) }
        let investigator = try #require(BuiltInAgents.named("investigator"))
        let second = try #require(BuiltInAgents.named("second-opinion"))
        let result = try await executor.execute(
            agentID: "planner", task: "lead", helpers: [
                AgentInvocation(definition: investigator, task: "slow first"),
                AgentInvocation(definition: second, task: "fast second"),
            ], primaryModel: "main/model"
        )
        #expect(result.output == "result lead")
        let calls = await recorder.calls
        #expect(Set(calls.prefix(2)) == Set(["slow first", "fast second"]))
        #expect(calls.last == "lead")
    }

    @Test func workflowSequenceParallelAskResumeAndCheckpoint() async throws {
        let recorder = WorkflowTestRecorder()
        let definition = WorkflowDefinition(id: "test", name: "Test", summary: "", steps: [
            .agent("one", title: "One", agent: "planner", instruction: "first"),
            .parallel("both", title: "Both", agents: [
                .agent("slow", title: "Slow", agent: "investigator", instruction: "slow review"),
                .agent("fast", title: "Fast", agent: "second-opinion", instruction: "fast review"),
            ]),
            .ask("ask", title: "Approval", question: "Continue?", options: ["Continue", "Stop"]),
            .agent("last", title: "Last", agent: "review-combiner", instruction: "finish"),
        ], isApproved: true)
        let engine = WorkflowEngine(definition: definition, runner: { try await recorder.run($0) }, checkpointer: { await recorder.save($0) })
        let first = await engine.run(request: "request")
        guard case .waiting(let checkpoint, let question) = first else { Issue.record("Expected pause"); return }
        #expect(question.nodeID == "ask")
        #expect(checkpoint.outputs.map(\.nodeID) == ["one", "slow", "fast"], "parallel results join in declared order")
        try await engine.answer(nodeID: "ask", answer: "Continue")
        let second = await engine.run()
        guard case .completed(let complete) = second else { Issue.record("Expected completion"); return }
        #expect(complete.outputs.map(\.nodeID) == ["one", "slow", "fast", "ask", "last"])
        #expect(complete.cumulativeCost == 0.04)
        #expect(await recorder.checkpoints.count >= 8)

        let stoppedRecorder = WorkflowTestRecorder()
        let stoppedEngine = WorkflowEngine(definition: definition, runner: { try await stoppedRecorder.run($0) })
        guard case .waiting = await stoppedEngine.run(request: "request") else { Issue.record("Expected pause before stop"); return }
        try await stoppedEngine.answer(nodeID: "ask", answer: "Stop")
        guard case .cancelled = await stoppedEngine.run() else { Issue.record("Expected Stop to cancel the workflow"); return }
        #expect(!(await stoppedRecorder.calls).contains("finish"))
    }

    @Test func workflowRepeatCompletesOrPausesAtMaximumAndCanStop() async throws {
        let successRecorder = WorkflowTestRecorder(goalOnCall: 2)
        let repeatNode = WorkflowNode.repeatUntil("repeat", title: "Improve", maximum: 3, goal: "verified", steps: [
            .agent("work", title: "Work", agent: "researcher", instruction: "improve")
        ])
        let definition = WorkflowDefinition(id: "repeat-test", name: "Repeat", summary: "", steps: [repeatNode], isApproved: true)
        let successful = WorkflowEngine(definition: definition, runner: { try await successRecorder.run($0) })
        guard case .completed(let complete) = await successful.run(request: "goal") else { Issue.record("Expected repeat completion"); return }
        #expect(complete.repeatIterations["repeat"] == 2)
        #expect((await successRecorder.calls).allSatisfy { $0.contains("Repeat goal: verified") && $0.contains("GOAL_MET") })

        let boundedRecorder = WorkflowTestRecorder()
        let bounded = WorkflowEngine(definition: definition, runner: { try await boundedRecorder.run($0) })
        guard case .waiting(let paused, let question) = await bounded.run(request: "goal") else { Issue.record("Expected maximum pause"); return }
        #expect(paused.repeatIterations["repeat"] == 3)
        #expect(question.options == ["Continue", "Stop"])
        try await bounded.answer(nodeID: "repeat", answer: "Stop")
        guard case .completed = await bounded.run() else { Issue.record("Expected stopped repeat to complete workflow"); return }
    }

    @Test func workflowRestoresCheckpointAndCancellationStopsRunningWork() async throws {
        let recorder = WorkflowTestRecorder()
        let definition = WorkflowDefinition(id: "restore", name: "Restore", summary: "", steps: [
            .agent("done", title: "Done", agent: "planner", instruction: "already"),
            .agent("slow", title: "Slow", agent: "planner", instruction: "slow next"),
        ], isApproved: true)
        var checkpoint = WorkflowCheckpoint(workflowID: definition.id, request: "request")
        checkpoint.statuses["done"] = .completed
        checkpoint.outputs = [WorkflowOutput(nodeID: "done", title: "Done", text: "saved")]
        let engine = WorkflowEngine(definition: definition, checkpoint: checkpoint, runner: { try await recorder.run($0) })
        let task = Task { await engine.run() }
        try await Task.sleep(nanoseconds: 10_000_000)
        await engine.cancel()
        guard case .cancelled(let cancelled) = await task.value else { Issue.record("Expected cancellation"); return }
        #expect(cancelled.outputs.first?.text == "saved")
        #expect(!(await recorder.calls).contains("already"))
    }

    @Test func cloudShellIsBoundedApprovalGatedAndLoggerRedacts() async throws {
        let root = FileManager.default.temporaryDirectory
        let tool = ProcessTool(directory: root)
        #expect(await tool.approvalRequest(for: ["command": "rm old.txt"]) != nil)
        #expect(await tool.approvalRequest(for: ["command": "python3 -c 'import os; os.remove(\"old.txt\")'"]) != nil)
        #expect(await tool.approvalRequest(for: ["command": "git status"]) == nil)
        let authorized = ProcessTool(directory: root, authorization: ChangeAuthorization(request: "Delete old.txt and update Package.swift"))
        #expect(await authorized.approvalRequest(for: ["command": "rm old.txt && printf update > Package.swift"]) == nil)
        let output = try await tool.run(arguments: ["command": "printf cloud-runner"], progress: { _ in })
        #expect(output.forModel == "Exit code: 0\ncloud-runner")
        let logger = RedactingLogger(secrets: ["secret-token"])
        #expect(logger.redact("value secret-token value") == "value *** value")
    }
}
