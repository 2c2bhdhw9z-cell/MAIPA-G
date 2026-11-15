import Foundation
import Testing
@testable import AgentCore

/// Owner, 15 November 2026: "Shouldn't have been able to stop in the fucking first place anyways."
/// His Continuum reply's runner was gone at 11:02 AM Eastern with an empty log, so the chat said
/// only "the runner stopped", and the note stayed up after he carried it on.
@Suite("A reply's runner can't be stopped by anything but Stop, and says why when it ends")
struct RunnerStopTests {
    #if os(Linux)
    static let onLinux = true
    #else
    static let onLinux = false
    #endif

    @Test("Why it ended is read from the computer: a restart, memory, a crash, or both killed at once")
    func endingReasons() {
        let restarted = VMControl.ending(from: "maipa-g-why-started 1000\nmaipa-g-why-restarted 2000\nmaipa-g-log\n")
        #expect(restarted.reason?.hasPrefix("your computer restarted at ") == true)

        let runnerOOM = VMControl.ending(from: "maipa-g-why-started 1000\nmaipa-g-why-oom [ 812.5] Out of memory: Killed process 4321 (MAIPAGRunner) total-vm:9000kB\nmaipa-g-log\n")
        #expect(runnerOOM.reason == "your computer ran out of memory and stopped it")

        let buildOOM = VMControl.ending(from: "maipa-g-why-started 1000\nmaipa-g-why-oom [ 812.5] Out of memory: Killed process 77 (rustc) total-vm:1kB\nmaipa-g-log\n")
        #expect(buildOOM.reason == "your computer ran out of memory and stopped rustc")

        let killed = VMControl.ending(from: "maipa-g-why-started 1000\nmaipa-g-log\nmaipa-g-runner-exit 137\n")
        #expect(killed.reason == "something on your computer force-stopped it")
        #expect(killed.lastWords == "maipa-g-runner-exit 137")

        let crashed = VMControl.ending(from: "maipa-g-why-started 1000\nmaipa-g-log\nFatal error: Index out of range\nmaipa-g-runner-exit 132\n")
        #expect(crashed.reason == "it crashed")

        // What happened on 15 November: the runner gone, its log empty, nothing else to say why.
        let together = VMControl.ending(from: "maipa-g-why-started 1000\nmaipa-g-log\n")
        #expect(together.reason?.contains("killed at the same moment") == true)

        #expect(VMControl.ending(from: "maipa-g-log\n").reason == nil)
    }

    @Test("The note says why, and once it carries on by itself the Tap retry goes")
    func notices() {
        let ended = VMNotices.runnerEnded(reason: "your computer ran out of memory and stopped it", lastWords: "")
        #expect(ended == "The runner on your computer stopped without finishing: your computer ran out of memory and stopped it. Tap retry to carry on from where it stopped.")
        #expect(VMNotices.isRunnerEnded(ended) && VMNotices.asksForRetry(ended))
        let carried = VMNotices.carriedOn(ended, at: "11:03 AM")
        #expect(carried == "The runner on your computer stopped without finishing: your computer ran out of memory and stopped it. The reply carried on by itself at 11:03 AM.")
        #expect(VMNotices.isCarriedOn(carried) && !VMNotices.asksForRetry(carried))
        // The note in his chat, from before this build, is recognised too.
        let earlier = "The reply ended on your computer without finishing (the runner stopped). Tap retry to carry on from where it stopped."
        #expect(VMNotices.asksForRetry(earlier))
        #expect(VMNotices.runnerEnded(reason: nil, lastWords: "") == "The runner on your computer stopped without finishing. Tap retry to carry on from where it stopped.")
    }

    @Test("Carrying the reply on takes away the note asking for Retry")
    func resumeClearsTheStopNote() async throws {
        var step = AssistantStep()
        step.text = "Working the 26."
        step.finishedAt = Date()
        let earlier = "The reply ended on your computer without finishing (the runner stopped). Tap retry to carry on from where it stopped."
        var stopped = AssistantTurn(status: .stopped, steps: [step], notices: [VMNotices.runningOnComputer, earlier])
        stopped.stoppedEarly = true
        var chat = Chat()
        chat.messages = [.user("Keep going on the 48 left"), ChatMessage(body: .assistant(stopped))]
        let transport = ScriptedTransport([.events([AgentLoopTests.text("Done."), AgentLoopTests.done])])
        let environment = AgentEnvironment(
            openRouter: OpenRouterClient(transport: transport, apiKey: "sk-test"),
            freeRoute: { AgentLoopTests.route() },
            onOutOfCredits: {}
        )
        var last: AssistantTurn?
        for await event in AgentLoop.run(AgentTurnInput(chat: chat, route: AgentLoopTests.route(), systemPrompt: "system", tools: [], resumeNote: AgentLoop.resumeNote(partialText: step.text)), environment: environment) {
            if case .updated(let turn, _) = event { last = turn }
        }
        let turn = try #require(last)
        #expect(turn.status == .done)
        #expect(!turn.notices.contains(earlier))
        #expect(turn.notices.contains(VMNotices.runningOnComputer))
    }

    @Test("The AI's commands are what the out-of-memory killer stops first", .enabled(if: onLinux))
    func commandsGoFirstWhenMemoryRunsOut() async throws {
        let home = try ComputerRunnerTests.temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let computer = ComputerControl.local(machine: "test", home: home)
        let output = ComputerControl.plainOutput(try await computer.run("cat /proc/self/oom_score_adj; bash -c 'cat /proc/self/oom_score_adj'"))
        #expect(output.split(whereSeparator: \.isNewline).map(String.init) == ["1000", "1000"], "\(output)")
    }

    @Test("A stop signal sent by name doesn't end the run; Stop still does", .enabled(if: onLinux))
    func strayStopSignalsAreIgnored() async throws {
        let home = try ComputerRunnerTests.temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let revision = String(repeating: "c", count: 40)
        try await ComputerRunnerTests.installFakeRunner(in: home, revision: revision)
        let vm = VMControl(computer: ComputerControl.local(machine: "test", home: home))
        let id = VMRun.newTurnID()
        try await vm.start(id: id, mode: .turn, revision: revision, request: Data("{}".utf8), secrets: VMSecrets(openRouterKey: nil, githubToken: nil))
        let folder = home.appendingPathComponent(VMRun.folder(id), isDirectory: true)
        for _ in 0..<50 where !FileManager.default.fileExists(atPath: folder.appendingPathComponent("fake-started").path) {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        // What `pkill -f runner` does: TERM, HUP and INT to every process whose command line
        // names it (here, the run's id: the launch script and the runner). "[t]urn-…" matches
        // them but not this shell's own command line.
        let pattern = "[t]" + id.dropFirst()
        try await ComputerRunnerTests.shell("""
        for s in TERM HUP INT; do pkill -"$s" -f '\(pattern)' || true; done
        """, in: home)
        try await Task.sleep(nanoseconds: 500_000_000)
        #expect(try await vm.poll(id: id, after: 0).runnerAlive)
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("fake-stopped").path))
        try await vm.stop(id: id, graceSeconds: 2, termSeconds: 1)
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("fake-stopped").path))
        #expect(try await vm.poll(id: id, after: 0).runnerAlive == false)
    }

    @Test("A runner killed together with its launch script says so, and a Retry keeps the old log", .enabled(if: onLinux))
    func killedTogetherSaysSo() async throws {
        let home = try ComputerRunnerTests.temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let revision = String(repeating: "d", count: 40)
        try await ComputerRunnerTests.installFakeRunner(in: home, revision: revision)
        let vm = VMControl(computer: ComputerControl.local(machine: "test", home: home))
        let id = VMRun.newTurnID()
        try await vm.start(id: id, mode: .turn, revision: revision, request: Data("{}".utf8), secrets: VMSecrets(openRouterKey: nil, githubToken: nil))
        let folder = home.appendingPathComponent(VMRun.folder(id), isDirectory: true)
        for _ in 0..<50 where !FileManager.default.fileExists(atPath: folder.appendingPathComponent("fake-started").path) {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        try await ComputerRunnerTests.shell("pkill -KILL -f '[t]\(id.dropFirst())' || true", in: home)
        var running = AssistantTurn()
        running.status = .running
        var last: AssistantTurn?
        for await event in AgentRun.onComputer(VMRunHandle(id: id, control: vm), startingTurn: running, pollInterval: 200_000_000, onState: { _ in }).events {
            if case .updated(let turn, _) = event { last = turn }
        }
        let notice = try #require(last?.notices.first(where: VMNotices.isRunnerEnded))
        #expect(notice.contains("killed at the same moment"), "\(notice)")
        #expect(notice.hasSuffix(VMNotices.tapRetry))

        try "the first run's last line\n".write(to: folder.appendingPathComponent("runner.log"), atomically: true, encoding: .utf8)
        try await vm.start(id: id, mode: .turn, revision: revision, request: Data("{}".utf8), secrets: VMSecrets(openRouterKey: nil, githubToken: nil))
        #expect((try? String(contentsOf: folder.appendingPathComponent("runner.log.1"), encoding: .utf8)) == "the first run's last line\n")
        try await vm.stop(id: id, graceSeconds: 2, termSeconds: 1)
    }
}
