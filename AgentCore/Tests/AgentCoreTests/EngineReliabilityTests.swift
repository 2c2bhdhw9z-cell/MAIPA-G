import Foundation
import Testing
@testable import AgentCore

/// The engine audit (owner: replies stuck on "Thinking…", Retry following runs that had ended,
/// steering that vanished): the reply loop, following a reply on the computer, the runner there,
/// and what sub-agents may spend.
@Suite("Engine reliability", .serialized)
struct EngineReliabilityTests {
    /// The computer's scripts use GNU tools and /proc, as the chat computer (Linux) has them.
    #if os(Linux)
    static let onLinux = true
    #else
    static let onLinux = false
    #endif

    // MARK: Helpers

    actor Counter {
        private(set) var value = 0
        func next() -> Int {
            value += 1
            return value
        }
    }

    actor Gate {
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            if isOpen { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func open() {
            isOpen = true
            for waiter in waiters { waiter.resume() }
            waiters.removeAll()
        }
    }

    actor InvocationLog {
        private(set) var limits: [String: Double] = [:]
        private var budgets: [ObjectIdentifier] = []

        func add(_ invocation: AgentInvocation) {
            limits[invocation.task] = invocation.spendLimit
            if let budget = invocation.sharedSpend { budgets.append(ObjectIdentifier(budget)) }
        }

        var sharedOneBudget: Bool { budgets.count == 2 && Set(budgets).count == 1 }
    }

    /// Runs commands on this machine like `ComputerControl.local`, except the ones `intercept`
    /// answers (a string) or fails (a throw); nil passes the command on.
    static func control(home: URL, intercept: @escaping @Sendable (String) async throws -> String?) -> ComputerControl {
        let local = ComputerControl.local(machine: "test", home: home)
        return ComputerControl(tools: local.tools, machine: "test", commandSizeLimit: nil) { name, arguments in
            let command = arguments["cmd"]?.arrayValue?.last?.stringValue ?? ""
            if let answer = try await intercept(command) { return (answer, false) }
            return try await local.call(name, arguments)
        }
    }

    /// A process that stays alive, to stand in for a runner the computer is still running.
    static func stayingAlive() throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["sleep", "60"]
        try process.run()
        return process
    }

    /// A run's folder on this machine with a live stand-in runner.
    static func liveRunFolder(home: URL, id: String, runner: Process) throws -> URL {
        let folder = home.appendingPathComponent(VMRun.folder(id), isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("steer", isDirectory: true), withIntermediateDirectories: true)
        try Data("\(runner.processIdentifier)\n".utf8).write(to: folder.appendingPathComponent("runner.pid"))
        return folder
    }

    static var runningTurn: AssistantTurn {
        var turn = AssistantTurn()
        turn.status = .running
        return turn
    }

    // MARK: Following a reply on the computer

    @Test("Steering put back goes first, in its own order")
    func prependKeepsOrder() async {
        let inbox = SteeringInbox()
        await inbox.enqueue("typed later")
        await inbox.prepend(["first", "  ", "second"])
        #expect(await inbox.drain() == ["first", "second", "typed later"])
    }

    @Test("A steer the computer didn't take goes out again first, and the ones after it aren't lost", .enabled(if: EngineReliabilityTests.onLinux))
    func failedSteerIsSentAgainInOrder() async throws {
        let home = try ComputerRunnerTests.temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let runner = try Self.stayingAlive()
        defer { runner.terminate() }
        let id = VMRun.newTurnID()
        let folder = try Self.liveRunFolder(home: home, id: id, runner: runner)
        let moves = Counter()
        // The second steer's last step (moving it into place) fails once.
        let control = Self.control(home: home) { command in
            if command.contains("maipa-g-steer-ok"), await moves.next() == 2 { throw ComputerControl.Failure.commandFailed("connection dropped") }
            return nil
        }
        let run = AgentRun.onComputer(VMRunHandle(id: id, control: VMControl(computer: control)), startingTurn: Self.runningTurn, pollInterval: 50_000_000) { _ in }
        await run.steer("first")
        await run.steer("second")
        await run.steer("third")
        var delivered: [String] = []
        for _ in 0..<200 {
            delivered = VMRunFiles.steers(in: folder, after: []).map(\.text)
            if delivered.count >= 3 { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        run.cancel()
        for await _ in run.events {}
        #expect(delivered == ["first", "second", "third"])
        #expect(await moves.value == 4)
    }

    @Test("Stop is sent again until the computer takes it, and then not again", .enabled(if: EngineReliabilityTests.onLinux))
    func stopIsSentAgainUntilItArrives() async throws {
        let home = try ComputerRunnerTests.temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let runner = try Self.stayingAlive()
        defer { runner.terminate() }
        let id = VMRun.newTurnID()
        _ = try Self.liveRunFolder(home: home, id: id, runner: runner)
        let stops = Counter()
        let control = Self.control(home: home) { command in
            guard command.contains("maipa-g-stopped") else { return nil }
            if await stops.next() < 3 { throw ComputerControl.Failure.machineUnavailable("asleep") }
            return "maipa-g-stopped"
        }
        let handle = VMRunHandle(id: id, control: VMControl(computer: control))
        let run = AgentRun.onComputer(handle, startingTurn: Self.runningTurn, pollInterval: 50_000_000) { _ in }
        await handle.requestStop()
        for _ in 0..<200 {
            if await stops.value >= 3 { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(await stops.value == 3)
        try await Task.sleep(nanoseconds: 500_000_000)
        #expect(await stops.value == 3)
        run.cancel()
        for await _ in run.events {}
    }

    @Test("A Stop that can't get through is given up on after a while, and the chat says so", .enabled(if: EngineReliabilityTests.onLinux))
    func stopThatNeverArrivesIsSurfaced() async throws {
        let home = try ComputerRunnerTests.temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let runner = try Self.stayingAlive()
        defer { runner.terminate() }
        let id = VMRun.newTurnID()
        _ = try Self.liveRunFolder(home: home, id: id, runner: runner)
        let stops = Counter()
        let control = Self.control(home: home) { command in
            guard command.contains("maipa-g-stopped") else { return nil }
            _ = await stops.next()
            throw ComputerControl.Failure.machineUnavailable("asleep")
        }
        let handle = VMRunHandle(id: id, control: VMControl(computer: control))
        let run = AgentRun.onComputer(handle, startingTurn: Self.runningTurn, pollInterval: 50_000_000, stopRetryWindow: 0.3) { _ in }
        let watchdog = Task {
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            run.cancel()
        }
        await handle.requestStop()
        var said = false
        for await event in run.events {
            if case .updated(let turn, _) = event, turn.notices.contains(VMNotices.stopFailed) {
                said = true
                break
            }
        }
        #expect(said)
        let triesBefore = await stops.value
        #expect(triesBefore >= 2)
        // Tapping Stop again tries again.
        await handle.requestStop()
        for _ in 0..<100 {
            if await stops.value > triesBefore { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(await stops.value > triesBefore)
        watchdog.cancel()
        run.cancel()
    }

    @Test("When following ends, tools still shown as running are settled", .enabled(if: EngineReliabilityTests.onLinux))
    func followerSettlesRunningTools() async throws {
        let home = try ComputerRunnerTests.temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        var turn = Self.runningTurn
        var step = AssistantStep()
        step.toolCalls = [ToolCallRecord(id: "c1", name: "run_command", arguments: "{}", summary: "Running npm test…")]
        turn.steps = [step]
        // No folder at all: the run's files are gone, so following ends straight away.
        let run = AgentRun.onComputer(VMRunHandle(id: VMRun.newTurnID(), control: VMControl(computer: .local(machine: "test", home: home))), startingTurn: turn, pollInterval: 50_000_000) { _ in }
        var last: AssistantTurn?
        for await event in run.events {
            if case .updated(let updated, _) = event { last = updated }
        }
        let finished = try #require(last)
        let call = try #require(finished.steps.first?.toolCalls.first)
        #expect(finished.status == .stopped)
        #expect(call.status != .running)
        #expect(call.result == AgentLoop.interruptedToolResult)
        #expect(call.finishedAt != nil)
    }

    @Test("Steering the runner hands back goes ahead of steering still waiting on the phone", .enabled(if: EngineReliabilityTests.onLinux))
    func handedBackSteeringGoesFirst() async throws {
        let home = try ComputerRunnerTests.temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let runner = try Self.stayingAlive()
        defer { runner.terminate() }
        let id = VMRun.newTurnID()
        let folder = try Self.liveRunFolder(home: home, id: id, runner: runner)
        let failedSteers = Counter()
        let control = Self.control(home: home) { command in
            if command.contains("/steer/") {
                _ = await failedSteers.next()
                throw ComputerControl.Failure.commandFailed("connection dropped")
            }
            return nil
        }
        let run = AgentRun.onComputer(VMRunHandle(id: id, control: VMControl(computer: control)), startingTurn: Self.runningTurn, pollInterval: 50_000_000) { _ in }
        await run.steer("typed on the phone later")
        for _ in 0..<200 {
            if await failedSteers.value > 0 { break }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        var done = Self.runningTurn
        done.status = .done
        let final = done
        let writer = VMStateWriter(folder: folder)
        try await writer.write { VMTurnState(id: id, seq: $0, phase: .finished, turn: final, unconsumedSteering: ["sent earlier"]) }
        for await _ in run.events {}
        #expect(await run.drainUnconsumedSteering() == ["sent earlier", "typed on the phone later"])
    }

    // MARK: The computer's files

    @Test("A state a phone may still be reading stays for a while after newer ones are written")
    func stateWriterKeepsRecentStates() async throws {
        let folder = try ComputerRunnerTests.temporaryHome()
        defer { try? FileManager.default.removeItem(at: folder) }
        let writer = VMStateWriter(folder: folder)
        for _ in 1...7 {
            try await writer.write { VMTurnState(id: "turn-x", seq: $0, phase: .running, turn: AssistantTurn()) }
        }
        let states = folder.appendingPathComponent("state", isDirectory: true)
        #expect(try FileManager.default.contentsOfDirectory(atPath: states.path).count == 7)
        // Once replaced long enough ago, the old ones go; the newest four always stay.
        let old = Date().addingTimeInterval(-200)
        let kept = VMStateWriter.prune([1: old, 2: old, 3: old, 4: old, 5: old, 6: old], newest: 7, alwaysKept: 4, keepFor: 120, maxKept: 400, in: states)
        #expect(try FileManager.default.contentsOfDirectory(atPath: states.path).sorted() == ["4.json.gz", "5.json.gz", "6.json.gz", "7.json.gz"])
        #expect(kept.keys.sorted() == [4, 5, 6])
    }

    @Test("However recent, no more than maxKept states stay")
    func stateWriterBoundsWhatItKeeps() async throws {
        let folder = try ComputerRunnerTests.temporaryHome()
        defer { try? FileManager.default.removeItem(at: folder) }
        let writer = VMStateWriter(folder: folder, keepFor: 120, maxKept: 5)
        for _ in 1...9 {
            try await writer.write { VMTurnState(id: "turn-x", seq: $0, phase: .running, turn: AssistantTurn()) }
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent("state").path).sorted()
        #expect(names == ["5.json.gz", "6.json.gz", "7.json.gz", "8.json.gz", "9.json.gz"])
    }

    @Test("A state deleted part way through reading is read again from the newest", .enabled(if: EngineReliabilityTests.onLinux))
    func pollReadsAgainWhenAStateVanishes() async throws {
        let home = try ComputerRunnerTests.temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let id = "turn-vanish"
        let folder = home.appendingPathComponent(VMRun.folder(id), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let writer = VMStateWriter(folder: folder, keepFor: 0)
        // Random bytes don't compress, so this state takes several reads.
        var noise = Data(count: 90_000)
        for index in noise.indices { noise[index] = UInt8.random(in: 0...255) }
        let staged = [CheckpointFile(.write(path: "big.bin", data: noise, existed: false))]
        try await writer.write { VMTurnState(id: id, seq: $0, phase: .running, turn: AssistantTurn(), staged: staged) }
        let reads = Counter()
        let control = Self.control(home: home) { command in
            if command.contains("tail -c +"), command.contains("/state/1.json.gz"), await reads.next() == 1 {
                // The runner moves on and the state being read is deleted.
                try await writer.write { VMTurnState(id: id, seq: $0, phase: .running, turn: AssistantTurn()) }
                try FileManager.default.removeItem(at: folder.appendingPathComponent("state/1.json.gz"))
            }
            return nil
        }
        let poll = try await VMControl(computer: control).poll(id: id, after: 0)
        #expect(poll.seq == 2)
        #expect(poll.state?.seq == 2)
    }

    @Test("Stop gives the runner time to finish, then sends SIGTERM, then SIGKILL", .enabled(if: EngineReliabilityTests.onLinux))
    func stopWaitsThenEscalates() async throws {
        #expect(VMControl.stopGraceSeconds == 20 && VMControl.stopTermSeconds == 5)
        let script = VMControl.stopScript(id: "turn-x")
        #expect(script.contains("-lt 200") && script.contains("-lt 50"))
        let term = try #require(script.range(of: "kill -TERM"))
        let kill = try #require(script.range(of: "kill -KILL"))
        #expect(term.lowerBound < kill.lowerBound)

        // A runner that takes a while to write its final state after the stop file appears is
        // given that time, not killed part way (the old 6-second limit did that).
        let home = try ComputerRunnerTests.temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let revision = String(repeating: "d", count: 40)
        try await ComputerRunnerTests.shell("""
        set -e
        d="$HOME/.maipa-g/runner/\(revision)"; mkdir -p "$d"
        cat > "$d/run.sh" <<'EOF'
        #!/bin/bash
        if [ "$1" = --probe ]; then echo maipag-runner-ok; exit 0; fi
        while [ ! -f "$2/stop" ]; do sleep 0.1; done
        sleep 1.5
        echo written > "$2/final-written"
        EOF
        chmod 755 "$d/run.sh"; touch "$d/ready"
        """, in: home)
        let vm = VMControl(computer: ComputerControl.local(machine: "test", home: home))
        let id = VMRun.newTurnID()
        try await vm.start(id: id, mode: .turn, revision: revision, request: Data("{}".utf8), secrets: VMSecrets(openRouterKey: nil, githubToken: nil))
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(try await vm.poll(id: id, after: 0).runnerAlive)
        try await vm.stop(id: id, graceSeconds: 4, termSeconds: 1)
        #expect(try await vm.poll(id: id, after: 0).runnerAlive == false)
        let written = home.appendingPathComponent(VMRun.folder(id)).appendingPathComponent("final-written")
        #expect(FileManager.default.fileExists(atPath: written.path))
    }

    @Test("Starting a reply again clears the last run's stop, states and steering, and keeps what it made", .enabled(if: EngineReliabilityTests.onLinux))
    func startClearsWhatTheLastRunLeft() async throws {
        let home = try ComputerRunnerTests.temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let revision = String(repeating: "c", count: 40)
        try await ComputerRunnerTests.installFakeRunner(in: home, revision: revision)
        let vm = VMControl(computer: ComputerControl.local(machine: "test", home: home))
        let id = VMRun.newTurnID()
        let folder = home.appendingPathComponent(VMRun.folder(id), isDirectory: true)
        let manager = FileManager.default
        try manager.createDirectory(at: folder.appendingPathComponent("state"), withIntermediateDirectories: true)
        try manager.createDirectory(at: folder.appendingPathComponent("steer"), withIntermediateDirectories: true)
        try manager.createDirectory(at: folder.appendingPathComponent("data/media"), withIntermediateDirectories: true)
        try Data().write(to: folder.appendingPathComponent("stop"))
        try Data("9\n".utf8).write(to: folder.appendingPathComponent("seq"))
        try Data("old".utf8).write(to: folder.appendingPathComponent("state/9.json.gz"))
        try Data("old steer".utf8).write(to: folder.appendingPathComponent("steer/0000000000001-a.txt"))
        try Data("picture".utf8).write(to: folder.appendingPathComponent("data/media/pic.png"))
        try await vm.start(id: id, mode: .turn, revision: revision, request: Data("{}".utf8), secrets: VMSecrets(openRouterKey: "k", githubToken: nil))
        for _ in 0..<50 where !manager.fileExists(atPath: folder.appendingPathComponent("fake-started").path) {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        try await Task.sleep(nanoseconds: 400_000_000)
        #expect(manager.fileExists(atPath: folder.appendingPathComponent("fake-started").path))
        // The old stop file would have stopped the new run at once.
        #expect(!manager.fileExists(atPath: folder.appendingPathComponent("fake-stopped").path))
        #expect(!manager.fileExists(atPath: folder.appendingPathComponent("seq").path))
        #expect(!manager.fileExists(atPath: folder.appendingPathComponent("state").path))
        #expect(VMRunFiles.steers(in: folder, after: []).isEmpty)
        #expect(manager.fileExists(atPath: folder.appendingPathComponent("data/media/pic.png").path))
        let poll = try await vm.poll(id: id, after: 0)
        #expect(poll.seq == 0 && poll.runnerAlive)
        try await vm.stop(id: id, graceSeconds: 3, termSeconds: 1)
        #expect(manager.fileExists(atPath: folder.appendingPathComponent("fake-stopped").path))
    }

    @Test("Steering that came too late goes back to the phone, after what the AI didn't take")
    func lateSteeringIsHandedBack() throws {
        #expect(VMTurnRunner.unconsumedSteering(inbox: ["one"], lateFiles: [" two ", ""]) == ["one", "two"])
        let folder = try ComputerRunnerTests.temporaryHome()
        defer { try? FileManager.default.removeItem(at: folder) }
        let steer = folder.appendingPathComponent("steer", isDirectory: true)
        try FileManager.default.createDirectory(at: steer, withIntermediateDirectories: true)
        try Data("seen".utf8).write(to: steer.appendingPathComponent("0000000000001-a.txt"))
        try Data("last second".utf8).write(to: steer.appendingPathComponent("0000000000002-b.txt"))
        let late = VMRunFiles.steers(in: folder, after: ["0000000000001-a.txt"]).map(\.text)
        #expect(late == ["last second"])
    }

    @Test("One handed-over token holder serves every GitHub user on the computer")
    func oneTokenHolderForEveryUser() async throws {
        let folder = try ComputerRunnerTests.temporaryHome()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("token-refresh.json.gz")
        let shared = HandedOverTokens(token: "old", refreshFile: file)
        try VMCoding.pack(VMSecrets(openRouterKey: nil, githubToken: "new")).write(to: file)
        #expect(try await shared.installationToken() == "new")
        #expect(try await shared.userToken() == "new")
        // Why there is only one: two holders on one file, and the first to look takes the token.
        let first = HandedOverTokens(token: "old", refreshFile: file)
        let second = HandedOverTokens(token: "old", refreshFile: file)
        try VMCoding.pack(VMSecrets(openRouterKey: nil, githubToken: "newer")).write(to: file)
        #expect(try await first.installationToken() == "newer")
        #expect(try await second.installationToken() == "old")
    }

    // MARK: The reply loop

    @Test("A reply picked up again whose last step was cut off carries on instead of being marked done")
    func cutOffReplyCarriesOn() async throws {
        var step = AssistantStep()
        step.text = "Here is the first half of the ans"
        step.finishedAt = Date()
        var chat = Chat()
        chat.messages = [.user("Explain it"), ChatMessage(body: .assistant(AssistantTurn(status: .stopped, steps: [step])))]
        let transport = ScriptedTransport([.events([AgentLoopTests.text("wer, and the rest."), AgentLoopTests.done])])
        let input = AgentTurnInput(chat: chat, route: AgentLoopTests.route(), systemPrompt: "system", tools: [])
        let turn = try #require(await ThinkingHangTests.lastTurn(input, ThinkingHangTests.environment(transport)))
        #expect(transport.requestCount == 1)
        #expect(turn.status == .done)
        #expect(turn.steps.count == 2)
        #expect(turn.stoppedEarly != true)
        #expect(transport.sentBodies.first?.jsonString().contains("Retry after an early stop") == true)
    }

    @Test("A last step the model finished itself is still done, with no new request")
    func finishedReplyStaysDone() async throws {
        var step = AssistantStep()
        step.text = "The whole answer."
        step.finishedAt = Date()
        step.finishReason = "stop"
        var chat = Chat()
        chat.messages = [.user("Explain it"), ChatMessage(body: .assistant(AssistantTurn(status: .stopped, steps: [step])))]
        let transport = ScriptedTransport([])
        let input = AgentTurnInput(chat: chat, route: AgentLoopTests.route(), systemPrompt: "system", tools: [])
        let turn = try #require(await ThinkingHangTests.lastTurn(input, ThinkingHangTests.environment(transport)))
        #expect(transport.requestCount == 0)
        #expect(turn.status == .done)
    }

    actor RunLog {
        private(set) var runs = 0
        func add() { runs += 1 }
    }

    /// A command that does something, then takes a long time.
    struct SideEffectTool: AgentTool {
        let log: RunLog
        let name = "run_command"
        var spec: ToolSpec { ToolSpec(name: name, description: "Run", parameters: ["type": "object"]) }
        func runningSummary(for arguments: JSONValue) -> String { "Running…" }
        func run(arguments: JSONValue, progress: @escaping @Sendable (String) -> Void) async throws -> ToolOutput {
            await log.add()
            try await Task.sleep(nanoseconds: 30_000_000_000)
            return ToolOutput(forModel: "done", summary: "Ran it")
        }
    }

    @Test("A tool stopped part way gets a result saying so, and carrying the reply on doesn't run it again")
    func interruptedToolIsNotRunAgain() async throws {
        let log = RunLog()
        let tools: [any AgentTool] = [SideEffectTool(log: log)]
        let first = ScriptedTransport([.events([AgentLoopTests.toolCall(id: "c1", name: "run_command", arguments: "{}"), AgentLoopTests.toolsDone])])
        let run = AgentLoop.start(
            AgentTurnInput(chat: AgentLoopTests.newChat("Deploy it"), route: AgentLoopTests.route(), systemPrompt: "system", tools: tools),
            environment: ThinkingHangTests.environment(first)
        )
        var stopped: AssistantTurn?
        var cancelled = false
        for await event in run.events {
            guard case .updated(let turn, _) = event else { continue }
            stopped = turn
            if !cancelled, turn.steps.last?.toolCalls.first?.status == .running {
                cancelled = true
                run.cancel()
            }
        }
        let turn = try #require(stopped)
        let call = try #require(turn.steps.last?.toolCalls.first)
        #expect(turn.status == .stopped)
        #expect(call.result == AgentLoop.interruptedToolResult)
        #expect(await log.runs == 1)

        var chat = AgentLoopTests.newChat("Deploy it")
        chat.messages[chat.messages.count - 1] = ChatMessage(body: .assistant(turn))
        let second = ScriptedTransport([.events([AgentLoopTests.text("I checked: it had already deployed."), AgentLoopTests.done])])
        let resumed = try #require(await ThinkingHangTests.lastTurn(
            AgentTurnInput(chat: chat, route: AgentLoopTests.route(), systemPrompt: "system", tools: tools, resumeNote: AgentLoop.resumeNote(partialText: "")),
            ThinkingHangTests.environment(second)
        ))
        #expect(await log.runs == 1)
        #expect(resumed.status == .done)
        #expect(second.sentBodies.first?.jsonString().contains("It may have partly run") == true)
    }

    // MARK: What sub-agents may spend

    @Test("Agents running side by side share one allowance")
    func sharedBudgetCountsEveryone() async {
        let budget = SharedSpendBudget(limit: 1.0)
        let a = UUID(), b = UUID()
        #expect(await budget.isExhausted(member: a, spent: 0.6) == false)
        #expect(await budget.isExhausted(member: b, spent: 0.3) == false)
        #expect(abs(await budget.remaining() - 0.1) < 1e-9)
        // What a member spent never goes down.
        await budget.record(member: a, spent: 0.5)
        #expect(abs(await budget.total() - 0.9) < 1e-9)
        #expect(await budget.isExhausted(member: b, spent: 0.4) == true)
    }

    @Test("A turn stops before asking the AI once the shared allowance is used up")
    func agentLoopChecksTheSharedAllowance() async throws {
        let budget = SharedSpendBudget(limit: 0.01)
        await budget.record(member: UUID(), spent: 0.01)
        let transport = ScriptedTransport([.events([AgentLoopTests.text("Hi"), AgentLoopTests.done])])
        var input = AgentTurnInput(chat: AgentLoopTests.newChat("Hi"), route: AgentLoopTests.route(), systemPrompt: "system", tools: [])
        input.sharedSpend = budget
        let turn = try #require(await ThinkingHangTests.lastTurn(input, ThinkingHangTests.environment(transport)))
        #expect(transport.requestCount == 0)
        #expect(turn.status == .waitingForUser)
        #expect(turn.spendCheck != nil)
    }

    @Test("A sub-agent the spending limit stopped is reported as stopped, not completed")
    func subAgentStoppedForBudget() async throws {
        let transport = ScriptedTransport([])
        let setup = SubAgentSetup(
            chatModel: .model("test/model"), thinking: .medium, primaryModelID: "test/model", primaryIsFree: false,
            account: AccountState(), catalogue: [:], openRouterAvailable: true, client: OpenRouterClient(transport: transport, apiKey: "sk-test"),
            changeTools: [], reportTools: [], prompt: { _, _ in "system" }
        )
        let budget = SharedSpendBudget(limit: 0.01)
        await budget.record(member: UUID(), spent: 0.02)
        var invocation = AgentInvocation(definition: try #require(BuiltInAgents.named("context-gatherer")), task: "Find the login screen", spendLimit: 0.005)
        invocation.sharedSpend = budget
        let result = try await setup.runner()(invocation)
        #expect(result.status == AgentExecutionResult.stoppedForBudgetStatus)
        #expect(result.output.contains("spending limit"))
        #expect(transport.requestCount == 0)

        let tool = KiroSubAgentTests.tool { _ in
            AgentExecutionResult(output: "Half of it.", model: "m", cost: 0.02, toolCallCount: 2, status: AgentExecutionResult.stoppedForBudgetStatus)
        }
        let output = try await tool.runLive(arguments: ["name": "context-gatherer", "prompt": "Find it", "explanation": "Finding it."], callID: "c1", existingSubagents: nil) { _ in }
        #expect(output.subagents?.first?.status == .cancelled)
        #expect(output.summary.contains("stopped"))
        #expect(output.forModel.contains("stopped at the spending limit"))
    }

    @Test("A sub-agent launched while another still runs gets what is left, not the whole allowance")
    func parallelLaunchesShareTheAllowance() async throws {
        let gatherer = try #require(BuiltInAgents.named("context-gatherer"))
        let log = InvocationLog()
        let release = Gate()
        let (started, startedSignal) = AsyncStream<Void>.makeStream()
        let coordinator = AgentHelperCoordinator(lead: SubAgentSetup.lead, definitions: [gatherer], context: "", spendLimit: 1.0) { invocation in
            await log.add(invocation)
            if invocation.task == "first" {
                await invocation.sharedSpend?.record(member: invocation.sharedSpendMember, spent: 0.6)
                startedSignal.yield()
                await release.wait()
                return AgentExecutionResult(output: "one", cost: 0.6)
            }
            return AgentExecutionResult(output: "two", cost: 0.1)
        }
        async let first = coordinator.launch([(agentID: "context-gatherer", task: "first")])
        var signals = started.makeAsyncIterator()
        _ = await signals.next()
        _ = try await coordinator.launch([(agentID: "context-gatherer", task: "second")])
        await release.open()
        _ = try await first
        let limits = await log.limits
        #expect(abs((limits["first"] ?? 0) - 1.0) < 1e-9)
        #expect(abs((limits["second"] ?? 0) - 0.4) < 1e-9)
        #expect(await log.sharedOneBudget)
        #expect(abs((await coordinator.spentFromBudget() ?? 0) - 0.7) < 1e-9)
    }

    @Test("A call that fails its checks doesn't use up a sub-agent place")
    func failedLaunchDoesNotCount() async throws {
        let gatherer = try #require(BuiltInAgents.named("context-gatherer"))
        var lead = try #require(BuiltInAgents.named("coder"))
        lead.maximumHelpers = 1
        let coordinator = AgentHelperCoordinator(lead: lead, definitions: [gatherer], context: "", spendLimit: nil) { _ in
            AgentExecutionResult(output: "ok")
        }
        await #expect(throws: AgentExecutorError.unknownAgent("nope")) {
            try await coordinator.launch([(agentID: "nope", task: "look")])
        }
        await #expect(throws: (any Error).self) {
            try await coordinator.launch([(agentID: "context-gatherer", task: "   ")])
        }
        let results = try await coordinator.launch([(agentID: "context-gatherer", task: "the real task")])
        #expect(results.first?.output == "ok")
        await #expect(throws: AgentExecutorError.tooManyHelpers(maximum: 1)) {
            try await coordinator.launch([(agentID: "context-gatherer", task: "one more")])
        }
    }

    @Test("A late, older card update never puts a background sub-agent card back")
    func olderCardUpdateIsDropped() async {
        let inbox = SteeringInbox()
        func patch(_ summary: String, _ sequence: Int) -> BackgroundSubagentCardPatch {
            BackgroundSubagentCardPatch(callID: "c1", update: ToolLiveUpdate(summary: summary), sequence: sequence)
        }
        await inbox.recordBackgroundCardPatch(patch("newer", 5))
        await inbox.recordBackgroundCardPatch(patch("older", 3))
        #expect(await inbox.drainCardPatches().map(\.update.summary) == ["newer"])
        // Still dropped after the newer one was taken.
        await inbox.recordBackgroundCardPatch(patch("older still", 4))
        #expect(await inbox.drainCardPatches().isEmpty)
        await inbox.completeBackgroundTask(UUID(), report: nil, finalPatch: patch("stale final", 2))
        #expect(await inbox.drainCardPatches().isEmpty)
        await inbox.recordBackgroundCardPatch(patch("newest", 6))
        #expect(await inbox.drainCardPatches().map(\.update.summary) == ["newest"])
        // Unnumbered updates are taken, as before.
        await inbox.recordBackgroundCardPatch(BackgroundSubagentCardPatch(callID: "c2", update: ToolLiveUpdate(summary: "plain")))
        #expect(await inbox.drainCardPatches().map(\.update.summary) == ["plain"])
        #expect(CardPatchClock.shared.next() < CardPatchClock.shared.next())
    }

    // MARK: Fitting the request

    @Test("Trimming keeps the person's latest message whole when MAIPA-G's own notes come after it")
    func fitProtectsTheRealLatestMessage() {
        let image: JSONValue = ["type": "image_url", "image_url": ["url": .string("data:image/png;base64," + String(repeating: "A", count: 100_000))]]
        let messages: [APIMessage] = [
            .system("system"),
            .user("old question"),
            APIMessage(role: .assistant, content: "old answer"),
            APIMessage(role: .user, content: nil, contentParts: [["type": "text", "text": "Fix this screen"], image]),
            APIMessage(role: .assistant, content: nil, toolCalls: [APIToolCall(id: "c1", name: "read_file", arguments: "{}")]),
            .tool(id: "c1", "contents"),
            .syntheticUser("Live steering from the user while you were working — incorporate this into your approach and answer:\nalso the header"),
        ]
        let fitted = Transcript.fit(messages, budget: 1_000_000, maxPayloadBytes: 50_000).messages
        #expect(fitted.contains { $0.contentParts?.contains { $0["type"]?.stringValue == "image_url" } == true })
    }

    @Test("Dropping old exchanges never cuts at MAIPA-G's own notes, nor trims this reply's tool output first")
    func fitKeepsTheCurrentExchange() {
        let big = String(repeating: "word ", count: 4_000)
        let messages: [APIMessage] = [
            .system("system"),
            .user("first question " + big),
            APIMessage(role: .assistant, content: "first answer " + big),
            .user("latest question"),
            APIMessage(role: .assistant, content: nil, toolCalls: [APIToolCall(id: "c1", name: "read_file", arguments: "{}")]),
            .tool(id: "c1", "file contents " + big),
            .syntheticUser("Live steering from the user while you were working — incorporate this into your approach and answer:\nand the footer"),
            APIMessage(role: .assistant, content: "Working on it"),
        ]
        let fitted = Transcript.fit(messages, budget: 3_000).messages
        #expect(fitted.contains { $0.content == "latest question" })
        #expect(fitted.contains { $0.toolCalls?.first?.id == "c1" })
        let tool = fitted.first { $0.role == .tool && $0.toolCallID == "c1" }
        #expect(tool != nil)
        #expect(tool?.content != Transcript.trimmedToolResult)
        #expect(!fitted.contains { $0.content?.hasPrefix("first question") == true })
    }

    @Test("Wire bytes count JSON escaping, so a request under the limit is still under it once encoded")
    func wireBytesCountEscaping() throws {
        let tricky = String(repeating: "line with \"quotes\" and \\ a backslash\n\t", count: 2_000) + "\u{01}"
        let messages: [APIMessage] = [
            .system("system"),
            .user(tricky),
            APIMessage(role: .assistant, content: nil, toolCalls: [APIToolCall(id: "call_0123456789abcdef", name: "edit_file", arguments: #"{"path":"a.swift","text":"let s = \"x\"\n"}"#)]),
            .tool(id: "call_0123456789abcdef", tricky),
            .syntheticUser(tricky),
        ]
        for message in messages {
            let encoded = try JSONCoding.encoder().encode(message)
            #expect(encoded.count <= Transcript.messageWireBytes(message))
        }
        // Escaping is counted: the plain length would be well under what is sent.
        #expect(Transcript.messageWireBytes(.user(tricky)) > tricky.utf8.count + tricky.utf8.count / 10)
        #expect(Transcript.defaultMaxPayloadBytes == 9_000_000)
        // MAIPA-G's own marker is never sent.
        let synthetic = String(decoding: try JSONCoding.encoder().encode(APIMessage.syntheticUser("note")), as: UTF8.self)
        #expect(!synthetic.contains("ynthetic"))
    }
}
