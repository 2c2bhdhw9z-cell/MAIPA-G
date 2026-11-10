import Foundation
import Testing
@testable import AgentCore

/// A stream that answers 200, then sends only OpenRouter keep-alive comments and never a word,
/// the way a provider that stalls behind OpenRouter looks. Optionally sends some text first.
final class KeepAliveOnlyTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let leadingEvents: [String]
    private var streamsOpened = 0
    private var streamsEnded = 0

    init(leadingEvents: [String] = []) {
        self.leadingEvents = leadingEvents
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        HTTPResponse(status: 404)
    }

    func stream(_ request: HTTPRequest) async throws -> HTTPStreamResponse {
        lock.withLock { streamsOpened += 1 }
        let lead = leadingEvents.map { "data: \($0)\n\n" }.joined()
        let body = AsyncThrowingStream<Data, Error> { continuation in
            let pump = Task {
                if !lead.isEmpty { continuation.yield(Data(lead.utf8)) }
                while !Task.isCancelled {
                    continuation.yield(Data(": OPENROUTER PROCESSING\n\n".utf8))
                    try? await Task.sleep(nanoseconds: 20_000_000)
                }
            }
            continuation.onTermination = { [weak self] _ in
                pump.cancel()
                self?.markEnded()
            }
        }
        return HTTPStreamResponse(status: 200, headers: ["content-type": "text/event-stream"], body: body)
    }

    private func markEnded() { lock.withLock { streamsEnded += 1 } }
    var opened: Int { lock.withLock { streamsOpened } }
    var ended: Int { lock.withLock { streamsEnded } }
}

/// A provider that never answers: each request waits, then its connection times out, the way
/// URLSession ends a request whose response headers never come.
final class TimingOutTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let delay: TimeInterval
    private var streamsOpened = 0

    init(delay: TimeInterval) {
        self.delay = delay
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        HTTPResponse(status: 404)
    }

    func stream(_ request: HTTPRequest) async throws -> HTTPStreamResponse {
        lock.withLock { streamsOpened += 1 }
        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        throw HTTPError.transport("The request timed out.", isOffline: false)
    }

    var opened: Int { lock.withLock { streamsOpened } }
}

/// "All it does is say Thinking, but then it never actually responds" (owner, 10 November 2026).
@Suite("Replies never hang on Thinking…")
struct ThinkingHangTests {
    static func environment(_ transport: any HTTPTransport, modelSilence: TimeInterval = 300, helperSilence: TimeInterval = 600) -> AgentEnvironment {
        var environment = AgentEnvironment(
            openRouter: OpenRouterClient(transport: transport, apiKey: "sk-test"),
            freeRoute: { AgentLoopTests.route() },
            onOutOfCredits: {}
        )
        environment.modelSilenceLimit = modelSilence
        environment.backgroundHelperSilenceLimit = helperSilence
        return environment
    }

    static func lastTurn(_ input: AgentTurnInput, _ environment: AgentEnvironment) async -> AssistantTurn? {
        var last: AssistantTurn?
        for await event in AgentLoop.run(input, environment: environment) {
            if case .updated(let turn, _) = event { last = turn }
        }
        return last
    }

    @Test("A stream that only sends keep-alives ends the turn with the early-stop notice, not Thinking… forever")
    func keepAliveOnlyStreamEndsTheTurn() async throws {
        let transport = KeepAliveOnlyTransport()
        let started = Date()
        let turn = await Self.lastTurn(
            AgentTurnInput(chat: AgentLoopTests.newChat("Hi"), route: AgentLoopTests.route(), systemPrompt: "system", tools: []),
            Self.environment(transport, modelSilence: 0.4)
        )
        let finished = try #require(turn)
        #expect(Date().timeIntervalSince(started) < 20)
        #expect(finished.status == .failed)
        #expect(finished.status != .running)
        #expect(finished.stoppedEarly == true)
        #expect(finished.notices.contains(AgentLoop.stoppedEarlyNotice))
        #expect(finished.failure?.kind == .providerFailed)
        #expect(finished.failure?.message.contains("sent nothing") == true)
        // Not retried quietly in the background: one request, and its connection was closed.
        #expect(transport.opened == 1)
        let deadline = Date().addingTimeInterval(5)
        while transport.ended == 0, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(transport.ended == 1)
    }

    @Test("Words that arrived before the stream went silent are kept, and the reply says it stopped early")
    func silenceAfterSomeWordsKeepsThem() async throws {
        let transport = KeepAliveOnlyTransport(leadingEvents: [AgentLoopTests.text("Half an ans")])
        let turn = await Self.lastTurn(
            AgentTurnInput(chat: AgentLoopTests.newChat("Hi"), route: AgentLoopTests.route(), systemPrompt: "system", tools: []),
            Self.environment(transport, modelSilence: 0.4)
        )
        let finished = try #require(turn)
        #expect(finished.status == .failed)
        #expect(finished.steps.last?.text == "Half an ans")
        #expect(finished.stoppedEarly == true)
        #expect(finished.notices.contains(AgentLoop.stoppedEarlyNotice))
    }

    @Test("The watchdog ends a stream that never sends anything, even before its first byte")
    func watchdogEndsANeverStartingStream() async {
        let stream = SilenceWatchdog.watch(limit: 0.2) {
            AsyncThrowingStream<Int, Error> { continuation in
                let hold = Task { try? await Task.sleep(nanoseconds: 60_000_000_000); continuation.finish() }
                continuation.onTermination = { _ in hold.cancel() }
            }
        }
        var caught: Error?
        do {
            for try await _ in stream {}
        } catch {
            caught = error
        }
        #expect(caught is ModelWentSilent)
    }

    @Test("A stream that keeps sending is never cut off by the watchdog")
    func watchdogLeavesASteadyStreamAlone() async throws {
        let stream = SilenceWatchdog.watch(limit: 1.0) {
            AsyncThrowingStream<Int, Error> { continuation in
                let pump = Task {
                    for value in 0..<30 {
                        continuation.yield(value)
                        try? await Task.sleep(nanoseconds: 50_000_000)
                    }
                    continuation.finish()
                }
                continuation.onTermination = { _ in pump.cancel() }
            }
        }
        var received: [Int] = []
        for try await value in stream { received.append(value) }
        #expect(received == Array(0..<30))
    }

    @Test("Thinking that never becomes an answer, even after the nudge, says it stopped early")
    func reasoningOnlyRepliesAreMarked() async throws {
        let thoughtOnly = [
            #"{"id":"g1","model":"test/model","choices":[{"index":0,"delta":{"reasoning":"Let me think."}}]}"#,
            AgentLoopTests.done,
        ]
        let transport = ScriptedTransport([.events(thoughtOnly), .events(thoughtOnly)])
        let (turn, _) = await AgentLoopTests.runToEnd(transport, chat: AgentLoopTests.newChat("Hi"), route: AgentLoopTests.route())
        let finished = try #require(turn)
        #expect(finished.status != .running)
        #expect(transport.requestCount == 2)
        #expect(finished.stoppedEarly == true)
        #expect(finished.notices.contains(AgentLoop.stoppedEarlyNotice))
    }

    @Test("A helper that finishes before it is registered can't leave the turn waiting forever")
    func helperFinishedBeforeRegistrationIsNotCounted() async {
        let inbox = SteeringInbox()
        let id = UUID()
        await inbox.completeBackgroundTask(id, report: "Helper report", finalPatch: nil)
        await inbox.registerBackgroundTask(id, task: Task {})
        #expect(await inbox.activeBackgroundTaskCount() == 0)
        #expect(await inbox.waitForActivity(timeout: 5) == true)
        #expect(await inbox.drainBackgroundReports() == ["Helper report"])
    }

    @Test("Waiting on silent helpers gives up after the limit")
    func activityWaitTimesOut() async {
        let inbox = SteeringInbox()
        let hang = Task { _ = try? await Task.sleep(nanoseconds: 60_000_000_000) }
        await inbox.registerBackgroundTask(UUID(), task: hang)
        let started = Date()
        let heardBack = await inbox.waitForActivity(timeout: 0.2)
        #expect(heardBack == false)
        #expect(Date().timeIntervalSince(started) < 10)
        await inbox.cancelAllBackgroundTasks()
        #expect(hang.isCancelled)
    }

    @Test("Activity still wakes a bounded wait straight away")
    func activityWakesABoundedWait() async {
        let inbox = SteeringInbox()
        let hang = Task { _ = try? await Task.sleep(nanoseconds: 60_000_000_000) }
        await inbox.registerBackgroundTask(UUID(), task: hang)
        let waiter = Task { await inbox.waitForActivity(timeout: 30) }
        try? await Task.sleep(nanoseconds: 50_000_000)
        await inbox.enqueue("change of plan")
        #expect(await waiter.value == true)
        await inbox.cancelAllBackgroundTasks()
    }

    @Test("Background helpers that go silent are stopped and the turn still answers")
    func silentBackgroundHelpersDoNotHangTheTurn() async throws {
        let inbox = SteeringInbox()
        let hang = Task { _ = try? await Task.sleep(nanoseconds: 60_000_000_000) }
        await inbox.registerBackgroundTask(UUID(), task: hang)
        let transport = ScriptedTransport([.events([AgentLoopTests.text("Here is what I have."), AgentLoopTests.done])])
        let turn = await Self.lastTurn(
            AgentTurnInput(chat: AgentLoopTests.newChat("Hi"), route: AgentLoopTests.route(), systemPrompt: "system", tools: [], steering: inbox),
            Self.environment(transport, helperSilence: 0.2)
        )
        let finished = try #require(turn)
        #expect(finished.status == .done)
        #expect(finished.steps.last?.text == "Here is what I have.")
        #expect(finished.notices.contains { $0.hasPrefix("Background sub-agents sent nothing") })
        #expect(hang.isCancelled)
        let body = try #require(transport.sentBodies.first)
        #expect(body["messages"]?.jsonString().contains("Background sub-agents stopped") == true)
    }

    @Test("Silence is counted across retries, so timed-out requests can't each restart the wait")
    func silenceCountsAcrossTimedOutRetries() async throws {
        // Build 148, 10 November 2026: a Claude reply sat on "Thinking…" for minutes. A request
        // times out (180 s) before the watchdog (300 s), and each retry used to get a fresh
        // watchdog, so three silent attempts ran back to back with nothing said.
        // Each attempt times out after 2 s and the limit is 3 s: the first attempt fits with a
        // second to spare even on a busy test machine, and the second can't.
        let transport = TimingOutTransport(delay: 2.0)
        let turn = await Self.lastTurn(
            AgentTurnInput(chat: AgentLoopTests.newChat("Hi"), route: AgentLoopTests.route(), systemPrompt: "system", tools: []),
            Self.environment(transport, modelSilence: 3.0)
        )
        let finished = try #require(turn)
        #expect(finished.status == .failed)
        #expect(finished.stoppedEarly == true)
        #expect(finished.notices.contains(AgentLoop.stoppedEarlyNotice))
        #expect(finished.failure?.message.contains("sent nothing") == true)
        // The second attempt only gets what is left of the limit; there is no third.
        #expect(transport.opened == 2)
    }
}
