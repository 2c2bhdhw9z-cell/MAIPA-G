import Foundation
import Testing
@testable import AgentCore

/// The chat computer runner: replies and jobs run on the person's Linux computer, and the phone
/// hands them over, follows them, steers and stops them. These run the real shell scripts against
/// this machine through `ComputerControl.local`, so only the Sprites connector itself is left out.
@Suite("Runs on the chat computer", .serialized)
struct ComputerRunnerTests {
    // MARK: Helpers

    /// The VM scripts use GNU tools and /proc, as the chat computer (Linux) has them.
    #if os(Linux)
    static let onLinux = true
    #else
    static let onLinux = false
    #endif

    /// The newest state the runner wrote, read straight from its files.
    static func latestState(in folder: URL) throws -> VMTurnState {
        let seq = try String(contentsOf: folder.appendingPathComponent("seq"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        return try VMCoding.unpack(VMTurnState.self, from: Data(contentsOf: folder.appendingPathComponent("state/\(seq).json.gz")))
    }

    static func temporaryHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("maipa-g-vm-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    static func shell(_ script: String, in home: URL) async throws -> String {
        let result = try await BoundedProcess.run(
            executable: "/bin/bash", arguments: ["-c", script], directory: home,
            environment: ComputerControl.localEnvironment(home: home, from: ProcessInfo.processInfo.environment), replacingEnvironment: true, timeout: 60
        )
        return result.stdout + result.stderr
    }

    /// A repo at ~/repos/o/r with one commit: a.txt and an executable run.sh.
    static func makeRepo(in home: URL) async throws -> String {
        try await shell("""
        set -e
        mkdir -p repos/o/r && cd repos/o/r
        git init -q
        printf 'one\\n' > a.txt
        printf '#!/bin/sh\\necho hi\\n' > run.sh && chmod 755 run.sh
        git add -A
        git -c user.name=t -c user.email=t@t commit -qm init
        """, in: home)
        return try await shell("cd repos/o/r && git rev-parse HEAD", in: home).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Staged edits survive a failure

    @Test("A failing staged sync never loses the computer's own edits")
    func failedSyncKeepsComputerEdits() async throws {
        let home = try Self.temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let commit = try await Self.makeRepo(in: home)
        let control = ComputerControl.local(machine: "test", home: home)
        try await Self.shell("printf 'made on the computer\\n' > repos/o/r/a.txt; printf 'new\\n' > repos/o/r/notes.txt", in: home)
        // a.txt is a file, so a staged file inside it can't be placed: the sync fails part way.
        let changes: [StagedChange] = [
            .write(path: "b.txt", data: Data("staged\n".utf8), existed: false),
            .write(path: "a.txt/inside.txt", data: Data("x".utf8), existed: false),
        ]
        await #expect(throws: ComputerControl.Failure.self) {
            try await control.syncStagedChanges(homePath: "repos/o/r", cloneURL: nil, commit: commit, changes: changes)
        }
        let stash = try await Self.shell("cd repos/o/r && git stash list && git stash show -p --include-untracked stash@{0}", in: home)
        #expect(stash.contains("maipa-g: computer edits kept"))
        #expect(stash.contains("made on the computer"))
        #expect(stash.contains("notes.txt"))
    }

    @Test("A failure before the copy changes leaves it exactly as it was")
    func unknownCommitLeavesCopyAlone() async throws {
        let home = try Self.temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let commit = try await Self.makeRepo(in: home)
        let control = ComputerControl.local(machine: "test", home: home)
        // Already synced once with a staged file, so the copy has MAIPA-G's own edit on it.
        _ = try await control.syncStagedChanges(homePath: "repos/o/r", cloneURL: nil, commit: commit, changes: [.write(path: "a.txt", data: Data("staged one\n".utf8), existed: true)])
        let missing = String(repeating: "e", count: 40)
        await #expect(throws: ComputerControl.Failure.self) {
            try await control.syncStagedChanges(homePath: "repos/o/r", cloneURL: nil, commit: missing, changes: [.write(path: "a.txt", data: Data("staged two\n".utf8), existed: true)])
        }
        // MAIPA-G's own synced tree isn't stashed, and the failed checkout changed nothing.
        let state = try await Self.shell("cd repos/o/r && cat a.txt && git stash list | wc -l", in: home)
        #expect(state.contains("staged one"))
        #expect(state.hasSuffix("0\n"))
    }

    @Test("A staged sync places every file, keeps modes, and stashes only real computer edits")
    func syncPlacesFilesAndStashesComputerEdits() async throws {
        let home = try Self.temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let commit = try await Self.makeRepo(in: home)
        let control = ComputerControl.local(machine: "test", home: home)
        let changes: [StagedChange] = [
            .write(path: "run.sh", data: Data("#!/bin/sh\necho staged\n".utf8), existed: true),
            .write(path: "dir/new.txt", data: Data([0, 1, 2, 255]), existed: false),
            .delete(path: "a.txt", previous: Data("one\n".utf8)),
        ]
        let first = try await control.syncStagedChanges(homePath: "repos/o/r", cloneURL: nil, commit: commit, changes: changes)
        #expect(!first.contains("maipa-g-stashed"))
        let placed = try await Self.shell("cd repos/o/r && ./run.sh && od -An -tu1 dir/new.txt && ls a.txt 2>&1; git stash list | wc -l", in: home)
        #expect(placed.contains("echo staged") == false)
        #expect(placed.contains("staged"))
        #expect(placed.contains("0   1   2 255"))
        #expect(placed.contains("No such file"))
        // Syncing again with MAIPA-G's own edits on the copy stashes nothing.
        let second = try await control.syncStagedChanges(homePath: "repos/o/r", cloneURL: nil, commit: commit, changes: changes)
        #expect(!second.contains("maipa-g-stashed"))
        // A command on the computer changed a file: that is kept before the next sync.
        try await Self.shell("printf 'by a command\\n' >> repos/o/r/dir/new.txt", in: home)
        let third = try await control.syncStagedChanges(homePath: "repos/o/r", cloneURL: nil, commit: commit, changes: changes)
        #expect(third.contains("maipa-g-stashed"))
        let stash = try await Self.shell("cd repos/o/r && git stash list | wc -l", in: home)
        #expect(stash.trimmingCharacters(in: .whitespacesAndNewlines) == "1")
    }

    // MARK: The run's files

    @Test("gzip round trip")
    func gzipRoundTrip() throws {
        let text = Data(String(repeating: "MAIPA-G runs on the computer. ", count: 5000).utf8)
        let packed = try GzipDeflater.compress(text)
        #expect(packed.count < text.count / 10)
        #expect(packed.prefix(2) == Data([0x1f, 0x8b]))
        #expect(try GzipDeflater.decompress(packed) == text)
        #expect(try GzipDeflater.decompress(GzipDeflater.compress(Data())) == Data())
        #expect(throws: (any Error).self) { try GzipDeflater.decompress(packed.prefix(packed.count / 2)) }
    }

    @Test("A turn request and state survive the trip to the computer")
    func protocolRoundTrip() throws {
        var chat = Chat()
        chat.messages.append(ChatMessage(body: .user(UserMessage(text: "hello"))))
        let attachment = UUID()
        let request = VMTurnRequest(
            id: VMRun.newTurnID(), chat: chat, route: ModelRouter.route(choice: .model("openai/gpt-5"), difficulty: .normal, thinking: .medium, account: AccountState(), catalogue: [:]), systemPrompt: "be kind",
            allowTools: true, spendLimit: 2, fallbackModels: ["x/y"], resumeNote: nil, lastUserMessage: "hello", webEnabled: true,
            repo: nil, attachmentData: [attachment: Data([1, 2, 3])]
        )
        let back = try VMCoding.unpack(VMTurnRequest.self, from: VMCoding.pack(request))
        // Dates go through JSON at whole-second precision; everything else is exact.
        #expect(back.id == request.id && back.systemPrompt == request.systemPrompt && back.chat.messages.count == 1)
        #expect(back.attachmentData == request.attachmentData && back.fallbackModels == ["x/y"] && back.webEnabled)
        #expect(back.spendLimit == 2 && back.lastUserMessage == "hello")
        #expect(back.route.route.model == "openai/gpt-5")
        #expect(VMRun.isRunID(request.id))
        #expect(!VMRun.isRunID("../x"))
        #expect(!VMRun.isRunID("turn-$(rm -rf ~)"))
        var turn = AssistantTurn()
        turn.status = .done
        let state = VMTurnState(id: request.id, seq: 3, phase: .finished, turn: turn, unconsumedSteering: ["later"])
        let stateBack = try VMCoding.unpack(VMTurnState.self, from: VMCoding.pack(state))
        #expect(stateBack.isFinished)
        #expect(stateBack.unconsumedSteering == ["later"])
    }

    @Test("Keys are read once and deleted, and redaction knows every one")
    func secretsAreTakenOnce() throws {
        let folder = try Self.temporaryHome()
        defer { try? FileManager.default.removeItem(at: folder) }
        let secrets = VMSecrets(openRouterKey: "sk-or-secret", githubToken: "ghs_secret", connectorSecrets: ["A": "conn-secret"])
        try VMCoding.pack(secrets).write(to: folder.appendingPathComponent("secrets.json.gz"))
        let taken = try VMRunFiles.takeSecrets(in: folder)
        #expect(taken.githubToken == "ghs_secret")
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("secrets.json.gz").path))
        #expect(throws: (any Error).self) { try VMRunFiles.takeSecrets(in: folder) }
        let logger = RedactingLogger(secrets: taken.allValues)
        let line = logger.redact("sk-or-secret ghs_secret conn-secret")
        #expect(!line.contains("secret"))
    }

    @Test("The child environment for commands carries no keys")
    func localEnvironmentIsClean() {
        let environment = ComputerControl.localEnvironment(home: URL(fileURLWithPath: "/home/u"), from: [
            "PATH": "/usr/bin", "OPENROUTER_API_KEY": "sk", "GITHUB_TOKEN": "ghs", "LANG": "C.UTF-8",
        ])
        #expect(environment["HOME"] == "/home/u")
        #expect(environment["PATH"] == "/usr/bin")
        #expect(environment["OPENROUTER_API_KEY"] == nil)
        #expect(environment["GITHUB_TOKEN"] == nil)
    }

    @Test("A fresh token handed over replaces the old one once")
    func handedOverTokenRefreshes() async throws {
        let folder = try Self.temporaryHome()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("token-refresh.json.gz")
        let tokens = HandedOverTokens(token: "old", refreshFile: file)
        #expect(try await tokens.installationToken() == "old")
        try VMCoding.pack(VMSecrets(openRouterKey: nil, githubToken: "new")).write(to: file)
        #expect(try await tokens.installationToken() == "new")
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(try await tokens.userToken() == "new")
    }

    @Test("States are numbered, and only the last few stay")
    func stateWriterNumbersAndPrunes() async throws {
        let folder = try Self.temporaryHome()
        defer { try? FileManager.default.removeItem(at: folder) }
        let writer = VMStateWriter(folder: folder)
        for _ in 1...7 {
            try await writer.write { VMTurnState(id: "turn-x", seq: $0, phase: .running, turn: AssistantTurn()) }
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent("state").path).sorted()
        #expect(names == ["4.json.gz", "5.json.gz", "6.json.gz", "7.json.gz"])
        #expect(try String(contentsOf: folder.appendingPathComponent("seq"), encoding: .utf8) == "7\n")
    }

    @Test("Steer files are taken oldest first, once each")
    func steerFilesInOrder() throws {
        let folder = try Self.temporaryHome()
        defer { try? FileManager.default.removeItem(at: folder) }
        let steer = folder.appendingPathComponent("steer")
        try FileManager.default.createDirectory(at: steer, withIntermediateDirectories: true)
        try Data("second".utf8).write(to: steer.appendingPathComponent("0000000000002-b.txt"))
        try Data("first".utf8).write(to: steer.appendingPathComponent("0000000000001-a.txt"))
        try Data("half".utf8).write(to: steer.appendingPathComponent("0000000000003-c.part"))
        let all = VMRunFiles.steers(in: folder, after: [])
        #expect(all.map(\.text) == ["first", "second"])
        #expect(VMRunFiles.steers(in: folder, after: Set(all.map(\.name))).isEmpty)
        #expect(!VMRunFiles.stopRequested(in: folder))
        try Data().write(to: folder.appendingPathComponent("stop"))
        #expect(VMRunFiles.stopRequested(in: folder))
    }

    // MARK: Handing over and following, through the real scripts

    @Test("Big uploads arrive whole, in pieces, readable only by the computer's user", .enabled(if: ComputerRunnerTests.onLinux))
    func chunkedUpload() async throws {
        let home = try Self.temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let vm = VMControl(computer: ComputerControl.local(machine: "test", home: home))
        var bytes = Data(count: VMControl.chunkBytes * 2 + 123)
        for index in bytes.indices { bytes[index] = UInt8(truncatingIfNeeded: index &* 31) }
        #expect(VMControl.uploadScripts(bytes, to: "x/file").count == 3)
        try await vm.upload(bytes, to: ".maipa-g/runs/turn-a/secrets.json.gz")
        let file = home.appendingPathComponent(".maipa-g/runs/turn-a/secrets.json.gz")
        #expect(try Data(contentsOf: file) == bytes)
        let mode = try await Self.shell("stat -c %a .maipa-g/runs/turn-a/secrets.json.gz", in: home)
        #expect(mode.trimmingCharacters(in: .whitespacesAndNewlines) == "600")
        await #expect(throws: (any Error).self) { try await vm.upload(bytes, to: "../escape") }
    }

    @Test("A poll picks up from the last state seen, reading big states in pieces", .enabled(if: ComputerRunnerTests.onLinux))
    func pollResumesAfterSeq() async throws {
        let home = try Self.temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let id = "turn-poll"
        let folder = home.appendingPathComponent(VMRun.folder(id), isDirectory: true)
        let vm = VMControl(computer: ComputerControl.local(machine: "test", home: home))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let empty = try await vm.poll(id: id, after: 0)
        #expect(empty.seq == 0 && empty.state == nil && !empty.missing && !empty.runnerAlive)
        let writer = VMStateWriter(folder: folder)
        // Random bytes don't compress, so this state takes several reads.
        var noise = Data(count: VMControl.chunkBytes * 2)
        for index in noise.indices { noise[index] = UInt8.random(in: 0...255) }
        let staged = [CheckpointFile(.write(path: "big.bin", data: noise, existed: false))]
        try await writer.write { VMTurnState(id: id, seq: $0, phase: .running, turn: AssistantTurn(), staged: staged) }
        let first = try await vm.poll(id: id, after: 0)
        #expect(first.seq == 1)
        #expect(first.state?.staged == staged)
        let again = try await vm.poll(id: id, after: 1)
        #expect(again.state == nil)
        var done = AssistantTurn()
        done.status = .done
        let finished = done
        try await writer.write { VMTurnState(id: id, seq: $0, phase: .finished, turn: finished) }
        let last = try await vm.poll(id: id, after: 1)
        #expect(last.state?.isFinished == true)
        try await vm.remove(id: id)
        #expect(try await vm.poll(id: id, after: 2).missing)
    }

    /// A stand-in runner: answers the probe, then waits for the stop file like the real one.
    static func installFakeRunner(in home: URL, revision: String) async throws {
        try await shell("""
        set -e
        d="$HOME/.maipa-g/runner/\(revision)"
        mkdir -p "$d"
        cat > "$d/run.sh" <<'EOF'
        #!/bin/bash
        if [ "$1" = --probe ]; then echo maipag-runner-ok; exit 0; fi
        echo "started $1" > "$2/fake-started"
        [ -f "$2/secrets.json.gz" ] && echo yes > "$2/fake-saw-secrets"
        rm -f "$2/secrets.json.gz"
        while [ ! -f "$2/stop" ]; do sleep 0.1; done
        echo stopped > "$2/fake-stopped"
        EOF
        chmod 755 "$d/run.sh"
        touch "$d/ready"
        """, in: home)
    }

    @Test("Hand over, steer and stop a run through the real scripts", .enabled(if: ComputerRunnerTests.onLinux))
    func launchSteerStop() async throws {
        let home = try Self.temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let revision = String(repeating: "a", count: 40)
        let vm = VMControl(computer: ComputerControl.local(machine: "test", home: home))
        let id = VMRun.newTurnID()
        await #expect(throws: (any Error).self) {
            try await vm.start(id: id, mode: .turn, revision: revision, request: Data("{}".utf8), secrets: VMSecrets(openRouterKey: "k", githubToken: nil))
        }
        try await Self.installFakeRunner(in: home, revision: revision)
        #expect(try await vm.ensureRunner(revision: revision) == .ready)
        try await vm.start(id: id, mode: .turn, revision: revision, request: Data("{}".utf8), secrets: VMSecrets(openRouterKey: "k", githubToken: nil))
        let folder = home.appendingPathComponent(VMRun.folder(id), isDirectory: true)
        var started = false
        for _ in 0..<50 where !started {
            started = FileManager.default.fileExists(atPath: folder.appendingPathComponent("fake-started").path)
            if !started { try await Task.sleep(nanoseconds: 100_000_000) }
        }
        #expect(started)
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("fake-saw-secrets").path))
        let polled = try await vm.poll(id: id, after: 0)
        #expect(polled.runnerAlive)
        #expect(polled.awake == "none")
        try await vm.steer(id: id, text: "also check the tests")
        #expect(VMRunFiles.steers(in: folder, after: []).map(\.text) == ["also check the tests"])
        try await vm.stop(id: id)
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("fake-stopped").path))
        #expect(try await vm.poll(id: id, after: 0).runnerAlive == false)
    }

    @Test("A run that won't stop is ended", .enabled(if: ComputerRunnerTests.onLinux))
    func stopKillsAStuckRunner() async throws {
        let home = try Self.temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let revision = String(repeating: "b", count: 40)
        try await Self.shell("""
        set -e
        d="$HOME/.maipa-g/runner/\(revision)"; mkdir -p "$d"
        printf '#!/bin/bash\\nif [ "$1" = --probe ]; then echo maipag-runner-ok; exit 0; fi\\ntrap "" TERM\\nwhile true; do sleep 0.2; done\\n' > "$d/run.sh"
        chmod 755 "$d/run.sh"; touch "$d/ready"
        """, in: home)
        let vm = VMControl(computer: ComputerControl.local(machine: "test", home: home))
        let id = VMRun.newTurnID()
        try await vm.start(id: id, mode: .turn, revision: revision, request: Data("{}".utf8), secrets: VMSecrets(openRouterKey: nil, githubToken: nil))
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(try await vm.poll(id: id, after: 0).runnerAlive)
        try await vm.stop(id: id)
        #expect(try await vm.poll(id: id, after: 0).runnerAlive == false)
    }

    @Test("The phone follows a reply on the computer, steers it, and gets unused steering back", .enabled(if: ComputerRunnerTests.onLinux))
    func followerFollowsSteersAndFinishes() async throws {
        let home = try Self.temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let id = VMRun.newTurnID()
        let folder = home.appendingPathComponent(VMRun.folder(id), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let vm = VMControl(computer: ComputerControl.local(machine: "test", home: home))
        let handle = VMRunHandle(id: id, control: vm)
        let writer = VMStateWriter(folder: folder)
        var running = AssistantTurn()
        running.status = .running
        running.steps = [AssistantStep()]
        let first = running
        // Staged files travel on their own, by version; the state only names the version.
        let staged = [CheckpointFile(.write(path: "a.txt", data: Data("edited".utf8), existed: true))]
        let version = try await writer.writeStaged(staged)
        try await writer.write { VMTurnState(id: id, seq: $0, phase: .running, turn: first, stagedVersion: version) }
        let seen = StateLog()
        let run = AgentRun.onComputer(handle, startingTurn: AssistantTurn(), pollInterval: 100_000_000) { state in
            await seen.add(state.seq)
            if let files = state.staged { await seen.setStaged(files) }
        }
        await run.steer("and the docs")
        let simulated = Task {
            // The runner side: wait for the steer file, then finish with one steer unused.
            for _ in 0..<100 where VMRunFiles.steers(in: folder, after: []).isEmpty { try? await Task.sleep(nanoseconds: 50_000_000) }
            var done = first
            done.status = .done
            done.steps.append(AssistantStep())
            let final = done
            try? await writer.write { VMTurnState(id: id, seq: $0, phase: .finished, turn: final, stagedVersion: version, unconsumedSteering: ["and the docs"]) }
        }
        var last: AssistantTurn?
        for await event in run.events {
            if case .updated(let turn, _) = event { last = turn }
        }
        await simulated.value
        #expect(last?.status == .done)
        #expect(await seen.all.last == 2)
        #expect(await run.drainUnconsumedSteering() == ["and the docs"])
        #expect(await seen.staged == staged)
    }

    @Test("A runner that ends without finishing says so", .enabled(if: ComputerRunnerTests.onLinux))
    func followerNoticesADeadRunner() async throws {
        let home = try Self.temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let id = VMRun.newTurnID()
        let folder = home.appendingPathComponent(VMRun.folder(id), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let vm = VMControl(computer: ComputerControl.local(machine: "test", home: home))
        var running = AssistantTurn()
        running.status = .running
        let run = AgentRun.onComputer(VMRunHandle(id: id, control: vm), startingTurn: running, pollInterval: 200_000_000) { _ in }
        var last: AssistantTurn?
        for await event in run.events {
            if case .updated(let turn, _) = event { last = turn }
        }
        #expect(last?.status == .stopped)
        #expect(last?.notices.contains(VMNotices.runnerEnded) == true)
    }

    @Test("Cancelling only stops following; the run's files stay for later", .enabled(if: ComputerRunnerTests.onLinux))
    func cancelDetaches() async throws {
        let home = try Self.temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let id = VMRun.newTurnID()
        let folder = home.appendingPathComponent(VMRun.folder(id), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("1\n".utf8).write(to: folder.appendingPathComponent("runner.pid"))
        let vm = VMControl(computer: ComputerControl.local(machine: "test", home: home))
        let run = AgentRun.onComputer(VMRunHandle(id: id, control: vm), startingTurn: AssistantTurn(), pollInterval: 100_000_000) { _ in }
        run.cancel()
        for await _ in run.events {}
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("stop").path))
        #expect(FileManager.default.fileExists(atPath: folder.path))
    }

    @Test("Runner install and launch scripts refuse odd revisions")
    func scriptsCheckTheirInputs() throws {
        #expect(throws: (any Error).self) { try VMControl.ensureRunnerScript(revision: "main; rm -rf ~") }
        let script = try VMControl.ensureRunnerScript(revision: String(repeating: "c", count: 40))
        #expect(script.contains("\nMAIPA_G_INSTALL\n"))
        #expect(script.contains("runner-$rev"))
        #expect(VMControl.launchScript(id: "turn-x", mode: .job, revision: String(repeating: "c", count: 40)).contains("\" job \"$d\""))
    }
}

actor StateLog {
    private(set) var all: [Int] = []
    private(set) var staged: [CheckpointFile]?
    func add(_ seq: Int) { all.append(seq) }
    func setStaged(_ files: [CheckpointFile]) { staged = files }
}

@Suite("The reply runner on the computer", .serialized)
struct VMTurnRunnerTests {
    @Test("A reply runs to the end on the computer, writing its state and deleting the keys")
    func replyRunsToTheEnd() async throws {
        let home = try ComputerRunnerTests.temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let id = VMRun.newTurnID()
        let folder = home.appendingPathComponent(VMRun.folder(id), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var chat = Chat()
        chat.messages.append(ChatMessage(body: .user(UserMessage(text: "say hi"))))
        chat.messages.append(ChatMessage(body: .assistant(AssistantTurn())))
        let request = VMTurnRequest(
            id: id, chat: chat, route: AgentLoopTests.route(), systemPrompt: "Be brief.", allowTools: true, spendLimit: nil,
            fallbackModels: [], resumeNote: nil, lastUserMessage: "say hi", webEnabled: false, repo: nil
        )
        try VMCoding.pack(request).write(to: folder.appendingPathComponent("request.json.gz"))
        try VMCoding.pack(VMSecrets(openRouterKey: "sk-test", githubToken: nil)).write(to: folder.appendingPathComponent("secrets.json.gz"))
        let transport = ScriptedTransport([.events([AgentLoopTests.text("Hi "), AgentLoopTests.text("there."), AgentLoopTests.done])])
        try await VMTurnRunner(folder: folder, home: home, machine: "test", transport: transport).run()
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("secrets.json.gz").path))
        let state = try ComputerRunnerTests.latestState(in: folder)
        #expect(state.isFinished)
        #expect(state.turn.status == .done)
        #expect(state.turn.steps.last?.text.contains("Hi there.") == true)
        // The AI was told where it runs.
        let sent = transport.sentBodies.first.map { "\($0)" } ?? ""
        #expect(sent.contains("Where this reply runs"))
    }

    @Test("A stop file ends a reply on the computer as stopped")
    func stopFileStopsTheReply() async throws {
        let home = try ComputerRunnerTests.temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let id = VMRun.newTurnID()
        let folder = home.appendingPathComponent(VMRun.folder(id), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var chat = Chat()
        chat.messages.append(ChatMessage(body: .user(UserMessage(text: "go"))))
        chat.messages.append(ChatMessage(body: .assistant(AssistantTurn())))
        let request = VMTurnRequest(
            id: id, chat: chat, route: AgentLoopTests.route(), systemPrompt: "", allowTools: true, spendLimit: nil,
            fallbackModels: [], resumeNote: nil, lastUserMessage: "go", webEnabled: false, repo: nil
        )
        try VMCoding.pack(request).write(to: folder.appendingPathComponent("request.json.gz"))
        try VMCoding.pack(VMSecrets(openRouterKey: "sk-test", githubToken: nil)).write(to: folder.appendingPathComponent("secrets.json.gz"))
        try Data().write(to: folder.appendingPathComponent("stop"))
        let transport = SlowTransport()
        try await VMTurnRunner(folder: folder, home: home, machine: "test", transport: transport).run()
        let state = try ComputerRunnerTests.latestState(in: folder)
        #expect(state.isFinished)
        #expect(state.turn.status != .running && state.turn.status != .done)
    }

    @Test("A reply that can't start on the computer finishes with the reason")
    func setupFailureIsReported() async throws {
        let home = try ComputerRunnerTests.temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let id = VMRun.newTurnID()
        let folder = home.appendingPathComponent(VMRun.folder(id), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var chat = Chat(repo: ChatRepo(ref: RepoRef(owner: "o", name: "r"), branch: "main", defaultBranch: "main", isPrivate: true))
        chat.messages.append(ChatMessage(body: .user(UserMessage(text: "go"))))
        let repo = VMTurnRepo(repo: chat.repo!, workingBranch: "main", commit: String(repeating: "a", count: 40), directSaveSetting: false, staged: [], receipts: [])
        let request = VMTurnRequest(
            id: id, chat: chat, route: AgentLoopTests.route(), systemPrompt: "", allowTools: true, spendLimit: nil,
            fallbackModels: [], resumeNote: nil, lastUserMessage: "go", webEnabled: false, repo: repo
        )
        try VMCoding.pack(request).write(to: folder.appendingPathComponent("request.json.gz"))
        // No GitHub token for a repo chat.
        try VMCoding.pack(VMSecrets(openRouterKey: "sk-test", githubToken: nil)).write(to: folder.appendingPathComponent("secrets.json.gz"))
        try await VMTurnRunner(folder: folder, home: home, machine: "test", transport: ScriptedTransport([])).run()
        let state = try ComputerRunnerTests.latestState(in: folder)
        #expect(state.isFinished)
        #expect(state.turn.status == .failed)
        #expect(state.error?.contains("couldn't start on your computer") == true)
    }
}

/// A model stream that never answers, for stopping a reply mid-way.
final class SlowTransport: HTTPTransport, @unchecked Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse { HTTPResponse(status: 404) }
    func stream(_ request: HTTPRequest) async throws -> HTTPStreamResponse {
        HTTPStreamResponse(status: 200, headers: [:], body: AsyncThrowingStream { continuation in
            let task = Task {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        })
    }
}
