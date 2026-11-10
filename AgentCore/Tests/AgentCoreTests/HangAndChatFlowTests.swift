import Foundation
import Testing
@testable import AgentCore

/// A tool whose request is cancelled from its own side (URLSession, a connector), with no Stop pressed.
struct SelfCancellingTool: AgentTool {
    let name = "read_file"
    var spec: ToolSpec { ToolSpec(name: name, description: "Read", parameters: ["type": "object"]) }
    func runningSummary(for arguments: JSONValue) -> String { "Reading…" }
    func run(arguments: JSONValue, progress: @escaping @Sendable (String) -> Void) async throws -> ToolOutput {
        throw CancellationError()
    }
}

/// A tool that works for a while, reporting progress all along, and then finishes.
struct BusyTool: AgentTool {
    let name = "read_file"
    var spec: ToolSpec { ToolSpec(name: name, description: "Read", parameters: ["type": "object"]) }
    func runningSummary(for arguments: JSONValue) -> String { "Reading…" }
    func run(arguments: JSONValue, progress: @escaping @Sendable (String) -> Void) async throws -> ToolOutput {
        for index in 1...10 {
            try await Task.sleep(nanoseconds: 100_000_000)
            progress("Part \(index)")
        }
        return ToolOutput(forModel: "all of it", summary: "Read all of it")
    }
}

/// A tool that never finishes and ignores cancellation, like a request with no timeout of its own.
struct StuckTool: AgentTool {
    let name = "read_file"
    var spec: ToolSpec { ToolSpec(name: name, description: "Read", parameters: ["type": "object"]) }
    func runningSummary(for arguments: JSONValue) -> String { "Reading…" }
    func run(arguments: JSONValue, progress: @escaping @Sendable (String) -> Void) async throws -> ToolOutput {
        await Task.detached { try? await Task.sleep(nanoseconds: 30_000_000_000) }.value
        return ToolOutput(forModel: "late", summary: "Late")
    }
}

@Suite("Hang paths, in-chat workflows, Spec plans and per-provider spend")
struct HangAndChatFlowTests {
    static func run(_ transport: ScriptedTransport, tools: [any AgentTool], toolLimit: TimeInterval = 1_200) async -> AssistantTurn? {
        var environment = ThinkingHangTests.environment(transport)
        environment.toolTimeLimit = toolLimit
        return await ThinkingHangTests.lastTurn(
            AgentTurnInput(chat: AgentLoopTests.newChat("Read it"), route: AgentLoopTests.route(), systemPrompt: "system", tools: tools),
            environment
        )
    }

    static let readCall = AgentLoopTests.toolCall(id: "c1", name: "read_file", arguments: #"{"path":"a.txt"}"#)

    // MARK: A — hangs

    @Test("A tool that throws CancellationError without Stop is a failed tool, and the turn carries on")
    func toolCancellationIsAFailedTool() async throws {
        let transport = ScriptedTransport([
            .events([Self.readCall, AgentLoopTests.toolsDone]),
            .events([AgentLoopTests.text("It couldn't be read."), AgentLoopTests.done]),
        ])
        let turn = try #require(await Self.run(transport, tools: [SelfCancellingTool()]))
        #expect(turn.status == .done)
        #expect(turn.steps.first?.toolCalls.first?.status == .failed)
        #expect(turn.steps.last?.text == "It couldn't be read.")
        #expect(transport.requestCount == 2)
    }

    @Test("A tool past its time limit is stopped and reported as failed, and the turn carries on")
    func toolTimeLimitStopsAStuckTool() async throws {
        let transport = ScriptedTransport([
            .events([Self.readCall, AgentLoopTests.toolsDone]),
            .events([AgentLoopTests.text("It took too long."), AgentLoopTests.done]),
        ])
        let started = Date()
        let turn = try #require(await Self.run(transport, tools: [StuckTool()], toolLimit: 0.3))
        #expect(Date().timeIntervalSince(started) < 10)
        #expect(turn.status == .done)
        let call = try #require(turn.steps.first?.toolCalls.first)
        #expect(call.status == .failed)
        #expect(call.result?.contains("sent no output or progress") == true)
    }

    @Test("A tool that keeps reporting progress is never cut off, however long it runs")
    func busyToolIsNotCutOff() async throws {
        let transport = ScriptedTransport([
            .events([Self.readCall, AgentLoopTests.toolsDone]),
            .events([AgentLoopTests.text("Done."), AgentLoopTests.done]),
        ])
        // Runs about 1 second in all, with progress every 0.1 seconds, against a 0.4 second limit.
        let turn = try #require(await Self.run(transport, tools: [BusyTool()], toolLimit: 0.4))
        #expect(turn.status == .done)
        let call = try #require(turn.steps.first?.toolCalls.first)
        #expect(call.status == .done)
        #expect(call.summary == "Read all of it")
    }

    @Test("bounded with an activity clock counts from the last sign of life")
    func boundedByInactivity() async throws {
        let clock = ActivityClock()
        let value = try await AgentLoop.bounded(seconds: 0.3, label: "busy", activity: clock) {
            for _ in 0..<8 {
                try await Task.sleep(nanoseconds: 100_000_000)
                clock.touch()
            }
            return 5
        }
        #expect(value == 5)
        let quiet = ActivityClock()
        await #expect(throws: ToolTimedOut.self) {
            try await AgentLoop.bounded(seconds: 0.2, label: "quiet", activity: quiet) {
                await Task.detached { try? await Task.sleep(nanoseconds: 30_000_000_000) }.value
                return 1
            }
        }
    }

    @Test("Stop ends a turn at once even while a tool ignores cancellation")
    func stopWinsOverAStuckTool() async throws {
        let transport = ScriptedTransport([.events([Self.readCall, AgentLoopTests.toolsDone])])
        var environment = ThinkingHangTests.environment(transport)
        environment.toolTimeLimit = 0
        let input = AgentTurnInput(chat: AgentLoopTests.newChat("Read it"), route: AgentLoopTests.route(), systemPrompt: "system", tools: [StuckTool()])
        let started = Date()
        let run = AgentLoop.start(input, environment: environment)
        var last: AssistantTurn?
        for await event in run.events {
            guard case .updated(let turn, _) = event else { continue }
            last = turn
            if turn.steps.first?.toolCalls.first?.status == .running { run.cancel() }
        }
        #expect(Date().timeIntervalSince(started) < 10)
        let stopped = try #require(last)
        #expect(stopped.status == .stopped)
    }

    @Test("bounded returns the work's value, times out, and returns at once on cancel")
    func boundedLimits() async throws {
        let value = try await AgentLoop.bounded(seconds: 5, label: "quick") { 7 }
        #expect(value == 7)
        let unlimited = try await AgentLoop.bounded(seconds: 0, label: "unlimited") { "ok" }
        #expect(unlimited == "ok")
        await #expect(throws: ToolTimedOut.self) {
            try await AgentLoop.bounded(seconds: 0.2, label: "slow") {
                await Task.detached { try? await Task.sleep(nanoseconds: 30_000_000_000) }.value
                return 1
            }
        }
        let started = Date()
        let task = Task {
            try await AgentLoop.bounded(seconds: 0, label: "stuck") {
                await Task.detached { try? await Task.sleep(nanoseconds: 30_000_000_000) }.value
                return 1
            }
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(Date().timeIntervalSince(started) < 5)
    }

    @Test("A reply that stays empty after every retry ends with the early-stop notice")
    func emptyReplyEndsStoppedEarly() async throws {
        let transport = ScriptedTransport(Array(repeating: .events([]), count: 4))
        let turn = try #require(await Self.run(transport, tools: []))
        #expect(turn.status == .failed)
        #expect(turn.stoppedEarly == true)
        #expect(turn.notices.contains(AgentLoop.stoppedEarlyNotice))
    }

    @Test("A step cut off mid-thought is cleared once the reply goes on to finish normally")
    func stoppedEarlyClearsOnANormalFinish() async throws {
        let cutOff = #"{"id":"g","model":"test/model","choices":[{"index":0,"delta":{"reasoning":"Thinking about it"}}]}"#
        let transport = ScriptedTransport([
            .events([cutOff]),
            .events([AgentLoopTests.text("Here is the answer."), AgentLoopTests.done]),
        ])
        let turn = try #require(await Self.run(transport, tools: []))
        #expect(turn.status == .done)
        #expect(turn.stoppedEarly != true)
        #expect(!turn.notices.contains(AgentLoop.stoppedEarlyNotice))
        #expect(turn.steps.last?.text == "Here is the answer.")
    }

    // MARK: B/C — in-chat workflows

    @Test("A workflow run in the chat reports progress and its result as the reply")
    func chatWorkflowReplies() throws {
        let definition = try #require(BuiltInWorkflows.all.first)
        var checkpoint = WorkflowCheckpoint(workflowID: definition.id, request: "Build it")
        var snapshot = ActiveWorkflowRunSnapshot(id: "r1", definition: definition, checkpoint: checkpoint, isRunning: true)
        #expect(snapshot.chatReply().hasPrefix("Running the \(definition.name) workflow in this chat: 0 of"))

        checkpoint.outputs = [WorkflowOutput(nodeID: "n", title: "Last", text: "  All done.  ")]
        snapshot = ActiveWorkflowRunSnapshot(id: "r1", definition: definition, checkpoint: checkpoint, isRunning: false)
        #expect(snapshot.chatReply() == "All done.")

        snapshot.errorMessage = "No credits."
        #expect(snapshot.chatReply() == "The \(definition.name) workflow didn't finish: No credits.")

        var stopped = WorkflowCheckpoint(workflowID: definition.id, request: "Build it")
        stopped.isCancelled = true
        #expect(ActiveWorkflowRunSnapshot(id: "r2", definition: definition, checkpoint: stopped, isRunning: false).chatReply()
            == "The \(definition.name) workflow was stopped before it finished.")
        #expect(ActiveWorkflowRunSnapshot(id: "r3", definition: definition, checkpoint: WorkflowCheckpoint(workflowID: definition.id, request: "x"), isRunning: false).chatReply()
            == "The \(definition.name) workflow finished.")
    }

    // MARK: D — Spec-mode plans

    static func turn(_ text: String, status: AssistantTurn.Status = .done) -> AssistantTurn {
        var step = AssistantStep()
        step.text = text
        return AssistantTurn(status: status, steps: [step])
    }

    @Test("Only a finished, numbered plan that changed nothing counts as a Spec plan")
    func specPlanExtraction() {
        let plan = "Here's the plan:\n1. Add the login screen\n2. Wire it to the API\n3) Add tests"
        #expect(SpecModePlan.extract(from: Self.turn(plan)) == plan)
        #expect(SpecModePlan.extract(from: Self.turn("Yes, that file exists.\n1. Only one step")) == nil)
        #expect(SpecModePlan.extract(from: Self.turn(plan, status: .failed)) == nil)
        var cut = Self.turn(plan)
        cut.stoppedEarly = true
        #expect(SpecModePlan.extract(from: cut) == nil)
    }

    @Test("A chat's plan creates its Specs entry, updates it, and starts a new one after approval")
    func chatPlanRecordsASpec() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("maipag-chatplan-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = SpecCoordinator(dataDirectory: root)
        let repo = RepoRef(owner: "octo", name: "app")
        let chatID = UUID()
        let first = try await coordinator.recordChatPlan(chatID: chatID, title: "Login", request: "Plan login", plan: "1. A\n2. B", repo: repo, branch: "main", defaultBranch: "main")
        #expect(first.chatID == chatID && first.requirements == "1. A\n2. B" && first.stage == .requirements)

        let updated = try await coordinator.recordChatPlan(chatID: chatID, title: "Login", request: "Plan login", plan: "1. A\n2. C", repo: repo, branch: "main", defaultBranch: "main")
        #expect(updated.id == first.id && updated.requirements == "1. A\n2. C")
        #expect(await coordinator.all().count == 1)

        _ = try await coordinator.approve(first.id, stage: .requirements)
        let next = try await coordinator.recordChatPlan(chatID: chatID, title: "Login", request: "More", plan: "1. D\n2. E", repo: repo, branch: "main", defaultBranch: "main")
        #expect(next.id != first.id && next.chatID == chatID)
        let other = try await coordinator.recordChatPlan(chatID: UUID(), title: "Login", request: "Other", plan: "1. F\n2. G", repo: repo, branch: "main", defaultBranch: "main")
        #expect(other.id != next.id)
        let reloaded = try #require(await coordinator.load(first.id))
        #expect(reloaded.chatID == chatID)
        await #expect(throws: SpecFailure.self) {
            try await coordinator.recordChatPlan(chatID: chatID, title: "Login", request: "x", plan: "  ", repo: repo, branch: "main", defaultBranch: "main")
        }
    }

    // MARK: E — per-provider spend

    @Test("Turns overlapping on one provider are shared; other providers are not")
    func balanceOverlaps() {
        var tracker = BalanceOverlapTracker()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let a = UUID(), b = UUID(), c = UUID()
        tracker.begin(a, provider: "openrouter", at: t0)
        tracker.begin(c, provider: "anthropic", at: t0)
        #expect(tracker.isActive(provider: "openrouter"))
        tracker.begin(b, provider: "openrouter", at: t0.addingTimeInterval(1))
        #expect(tracker.end(b, at: t0.addingTimeInterval(2)) == true)
        #expect(tracker.end(a, at: t0.addingTimeInterval(3)) == true)
        #expect(tracker.end(c, at: t0.addingTimeInterval(3)) == false)
        #expect(!tracker.isActive(provider: "openrouter"))
    }

    @Test("A reply that starts during the previous one's recheck window makes both estimated")
    func recheckWindowOverlap() {
        var tracker = BalanceOverlapTracker()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let first = UUID(), second = UUID(), later = UUID()
        tracker.begin(first, provider: "openrouter", at: t0)
        #expect(tracker.end(first, at: t0.addingTimeInterval(10)) == false)
        // Starts 5 seconds after the first ended: inside its 20-second recheck window.
        tracker.begin(second, provider: "openrouter", at: t0.addingTimeInterval(15))
        #expect(tracker.isShared(first))
        #expect(tracker.end(second, at: t0.addingTimeInterval(20)) == true)
        // Long after both settled: clean.
        tracker.begin(later, provider: "openrouter", at: t0.addingTimeInterval(100))
        #expect(tracker.end(later, at: t0.addingTimeInterval(110)) == false)
    }

    @Test("A provider a reply switched to mid-turn counts for overlap when it ends")
    func switchedProviderOverlap() {
        var tracker = BalanceOverlapTracker()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let a = UUID(), b = UUID()
        tracker.begin(a, provider: "openrouter", at: t0)
        tracker.begin(b, provider: "oneprovider", at: t0.addingTimeInterval(1))
        #expect(tracker.end(a, providers: ["openrouter", "oneprovider"], at: t0.addingTimeInterval(5)) == true)
        #expect(tracker.isShared(b))
    }

    @Test("A reply that switched provider costs the drop on each provider it used, added up")
    func multiProviderRealCost() {
        var first = AssistantStep()
        first.provider = "openrouter"
        var second = AssistantStep()
        second.provider = "oneprovider"
        var turn = AssistantTurn(status: .done, steps: [first, second])
        turn.balanceBefore = 10
        turn.balanceProvider = "openrouter"
        turn.balancesBefore = ["openrouter": 10, "oneprovider": 5, "unused": 3]
        turn.balancesAfter = ["openrouter": 9.75, "oneprovider": 4.5, "unused": 1]
        turn.balanceAfter = 9.75
        #expect(turn.providersUsed == ["openrouter", "oneprovider"])
        #expect(abs((turn.realCost ?? 0) - 0.75) < 0.000_001)
        // A provider with no reading leaves the real cost unknown rather than undercounted.
        turn.balancesAfter = ["openrouter": 9.75]
        #expect(turn.realCost == nil)
    }

    @Test("Each step records whose balance it spent")
    func stepsRecordTheirProvider() async throws {
        let transport = ScriptedTransport([.events([AgentLoopTests.text("Hi."), AgentLoopTests.done])])
        let turn = try #require(await Self.run(transport, tools: []))
        #expect(turn.steps.first?.provider == "openrouter")
        #expect(turn.providersUsed == ["openrouter"])
    }

    @Test("A shared balance difference is an estimate, never a real cost")
    func sharedBalanceIsEstimated() {
        var turn = AssistantTurn(status: .done)
        turn.balanceBefore = 10
        turn.balanceAfter = 9.5
        turn.balanceProvider = "openrouter"
        #expect(turn.realCost == 0.5)
        turn.balanceShared = true
        #expect(turn.realCost == nil)
        #expect(turn.sharedBalanceCost == 0.5)
        var chat = Chat()
        chat.messages = [.user("a"), ChatMessage(body: .assistant(turn))]
        let summary = chat.spendSummary
        #expect(summary.realTurns == 0 && summary.hasEstimate && !summary.hasUnknownPrice)
        #expect(abs((summary.dollars ?? 0) - 0.5) < 0.000_001)
    }
}
