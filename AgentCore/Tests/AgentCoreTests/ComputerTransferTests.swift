import Foundation
import Testing
@testable import AgentCore

/// 11 November 2026: every long command to the Sprite failed with "Sprite returned 414" (its
/// `exec` carries the command in the web address), and private repos were never copied onto the
/// computer, so commands failed with "cd: ~/repos/…: No such file or directory". These run real
/// shell scripts against a stand-in Sprite that refuses long commands the same way.
@Suite("Getting work onto the computer", .serialized)
struct ComputerTransferTests {
    #if os(Linux)
    static let onLinux = true
    #else
    static let onLinux = false
    #endif

    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _execs: [String] = []
        private var _writes: [String] = []
        var execs: [String] { lock.lock(); defer { lock.unlock() }; return _execs }
        var writes: [String] { lock.lock(); defer { lock.unlock() }; return _writes }
        func exec(_ script: String) { lock.lock(); _execs.append(script); lock.unlock() }
        func write(_ content: String) { lock.lock(); _writes.append(content); lock.unlock() }
    }

    static let execTool = ConnectorToolDefinition(
        serverID: "mcp:sprites", serverName: "Sprites", originalName: "exec", description: "Run a command",
        inputSchema: ["type": "object", "properties": ["sprite": ["type": "string"], "cmd": ["type": "array", "items": ["type": "string"]], "workingDir": ["type": "string"]], "required": ["sprite", "cmd"]]
    )
    static let fileWriteTool = ConnectorToolDefinition(
        serverID: "mcp:sprites", serverName: "Sprites", originalName: "file_write", description: "Write a file",
        inputSchema: ["type": "object", "properties": ["sprite": ["type": "string"], "path": ["type": "string"], "content": ["type": "string"], "workingDir": ["type": "string"]], "required": ["sprite", "path", "content"]]
    )

    /// A Sprite stand-in: commands run in a real shell with HOME at `home`; one longer than the
    /// real service accepts gets its 414.
    static func sprite(home: URL, withFileTool: Bool, extraPath: String? = nil, recorder: Recorder) -> ComputerControl {
        var environment = ComputerControl.localEnvironment(home: home, from: ProcessInfo.processInfo.environment)
        if let extraPath { environment["PATH"] = extraPath + ":" + (environment["PATH"] ?? "/usr/bin:/bin") }
        let childEnvironment = environment
        let tools = withFileTool ? [execTool, fileWriteTool] : [execTool]
        return ComputerControl(tools: tools, machine: "mcp-maipa-g") { name, arguments in
            if name == "file_write" {
                let path = arguments["path"]?.stringValue ?? ""
                let content = arguments["content"]?.stringValue ?? ""
                recorder.write(content)
                guard path.hasPrefix(home.path + "/") else { return ("path outside home", true) }
                try FileManager.default.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(content.utf8).write(to: URL(fileURLWithPath: path))
                return ("{\"mode\":\"644\",\"path\":\"\(path)\",\"size\":\(content.utf8.count)}", false)
            }
            let argv = arguments["cmd"]?.arrayValue?.compactMap(\.stringValue) ?? []
            guard argv.count == 3 else { return ("bad cmd", true) }
            recorder.exec(argv[2])
            if argv[2].utf8.count > 2_400 { return ("Sprite returned 414: ", true) }
            let result = try await BoundedProcess.run(
                executable: "/bin/bash", arguments: ["-lc", argv[2]], directory: home,
                environment: childEnvironment, replacingEnvironment: true, timeout: 60, outputLimit: 400_000
            )
            // Sprites' framing: stdout pieces start with 0x01, stderr with 0x02, and 0x03 + the
            // exit code ends it.
            var text = ""
            if !result.stdout.isEmpty { text += "\u{1}" + result.stdout }
            if !result.stderr.isEmpty { text += "\u{2}" + result.stderr }
            text += "\u{3}" + String(UnicodeScalar(UInt8(clamping: result.exitCode)))
            return (text, false)
        }
    }

    static func temporaryHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("maipa-g-transfer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("A script longer than the service allows is uploaded and run from a file", .enabled(if: ComputerTransferTests.onLinux))
    func longScriptsRunFromAFile() async throws {
        let home = try Self.temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        for withFileTool in [true, false] {
            let recorder = Recorder()
            let control = Self.sprite(home: home, withFileTool: withFileTool, recorder: recorder)
            let script = (0..<600).map { "x\($0)=\($0)" }.joined(separator: "\n") + "\necho long-script-ran $x599"
            #expect(script.utf8.count > 4_000)
            let output = try await control.run(script)
            #expect(output.contains("long-script-ran 599"))
            #expect(recorder.execs.allSatisfy { $0.utf8.count <= 2_400 })
            let scripts = (try? FileManager.default.contentsOfDirectory(atPath: home.appendingPathComponent(".maipa-g/scripts").path)) ?? []
            #expect(scripts.isEmpty)
        }
    }

    @Test("Files arrive whole through the file tool or short commands, readable only by the computer's user", .enabled(if: ComputerTransferTests.onLinux))
    func filesArriveWhole() async throws {
        let home = try Self.temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        for (withFileTool, size) in [(true, 2_500_000), (false, 9_000)] {
            let recorder = Recorder()
            let control = Self.sprite(home: home, withFileTool: withFileTool, recorder: recorder)
            var bytes = Data(count: size)
            for index in bytes.indices { bytes[index] = UInt8.random(in: 0...255) }
            let path = ".maipa-g/runs/turn-x/request-\(withFileTool).json.gz"
            try await control.writeFile(bytes, toHomePath: path)
            #expect(try Data(contentsOf: home.appendingPathComponent(path)) == bytes)
            let mode = try await BoundedProcess.run(executable: "/usr/bin/stat", arguments: ["-c", "%a", home.appendingPathComponent(path).path], directory: home, timeout: 10).stdout
            #expect(mode.trimmingCharacters(in: .whitespacesAndNewlines) == "600")
            #expect(recorder.execs.allSatisfy { $0.utf8.count <= 2_400 })
            if withFileTool { #expect(recorder.writes.count == 3) } else { #expect(recorder.writes.isEmpty) }
        }
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: home.appendingPathComponent(".maipa-g/incoming").path)) ?? []
        #expect(leftovers.isEmpty)
    }

    @Test("A private repo is copied with its token without the token ever being in a command", .enabled(if: ComputerTransferTests.onLinux))
    func privateRepoIsCloned() async throws {
        let home = try Self.temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        // A stand-in git: "clones" by making the folder, and records whether the token reached it
        // through git's own environment.
        let bin = home.appendingPathComponent("fakebin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let fakeGit = """
        #!/bin/bash
        if [ "$1" = clone ]; then
          mkdir -p "$4/.git"; echo "${GIT_CONFIG_VALUE_0:-none}" > "$HOME/git-saw-header"; exit 0
        fi
        if [ "$1" = -C ] && [ "$3" = cat-file ]; then exit 1; fi
        exit 0
        """
        try Data(fakeGit.utf8).write(to: bin.appendingPathComponent("git"))
        _ = try await BoundedProcess.run(executable: "/bin/chmod", arguments: ["755", bin.appendingPathComponent("git").path], directory: home, timeout: 10)
        let recorder = Recorder()
        let control = Self.sprite(home: home, withFileTool: true, extraPath: bin.path, recorder: recorder)
        let token = "ghs_secretTOKENvalue123"
        try await control.ensureCheckout(homePath: "repos/me/private-app", cloneURL: "https://github.com/me/private-app.git", commit: "abc1234", token: { token })
        #expect(FileManager.default.fileExists(atPath: home.appendingPathComponent("repos/me/private-app/.git").path))
        let header = try String(contentsOf: home.appendingPathComponent("git-saw-header"), encoding: .utf8)
        #expect(header.contains("AUTHORIZATION: basic " + Data("x-access-token:\(token)".utf8).base64EncodedString()))
        // The token is never in a command, and its file is gone.
        let encoded = Data("x-access-token:\(token)".utf8).base64EncodedString()
        #expect(recorder.execs.allSatisfy { !$0.contains(token) && !$0.contains(encoded) })
        let secrets = (try? FileManager.default.contentsOfDirectory(atPath: home.appendingPathComponent(".maipa-g/secrets").path)) ?? []
        #expect(secrets.isEmpty)
    }

    @Test("A folder in the way of the repo's copy is moved aside, never deleted", .enabled(if: ComputerTransferTests.onLinux))
    func folderInTheWayIsKept() async throws {
        let home = try Self.temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let bin = home.appendingPathComponent("fakebin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try Data("#!/bin/bash\nif [ \"$1\" = clone ]; then mkdir -p \"$4/.git\"; fi\nexit 0\n".utf8).write(to: bin.appendingPathComponent("git"))
        _ = try await BoundedProcess.run(executable: "/bin/chmod", arguments: ["755", bin.appendingPathComponent("git").path], directory: home, timeout: 10)
        let stray = home.appendingPathComponent("repos/me/app/notes.txt")
        try FileManager.default.createDirectory(at: stray.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("keep me".utf8).write(to: stray)
        let control = Self.sprite(home: home, withFileTool: false, extraPath: bin.path, recorder: Recorder())
        try await control.ensureCheckout(homePath: "repos/me/app", cloneURL: "https://github.com/me/app.git", commit: nil, token: nil)
        let siblings = try FileManager.default.contentsOfDirectory(atPath: home.appendingPathComponent("repos/me").path)
        let kept = siblings.first { $0.hasPrefix("app.before-maipa-g-") }
        #expect(kept != nil)
        if let kept { #expect(try String(contentsOf: home.appendingPathComponent("repos/me/\(kept)/notes.txt"), encoding: .utf8) == "keep me") }
    }

    @Test("Commands copy the repo first, and say so plainly when it isn't there")
    func runCommandCopiesTheRepoFirst() async throws {
        let recorder = Recorder()
        let control = ComputerControl(tools: [Self.execTool], machine: "mcp-maipa-g") { _, arguments in
            let script = arguments["cmd"]?.arrayValue?.compactMap(\.stringValue).last ?? ""
            recorder.exec(script)
            if script.contains("maipa-g-checkout-present") { return ("maipa-g-checkout-missing", false) }
            if script.contains("git clone") { return ("fatal: repository not found\nmaipa-g-clone-failed", false) }
            return ("(MAIPA-G: ~/repos/me/app isn't on this computer, so this ran in /home/sprite)\nhello", false)
        }
        let checkout = CheckoutPreparer(control: control, homePath: "repos/me/app", cloneURL: "https://github.com/me/app.git", commit: nil, token: nil)
        let tool = RunCommandTool(control: control, homePath: "repos/me/app", checkout: checkout)
        let output = try await tool.runApproved(arguments: ["command": "echo hello"], progress: { _ in })
        #expect(output.forModel.contains("couldn't copy the repo onto the computer"))
        #expect(output.forModel.contains("repository not found"))
        #expect(output.forModel.contains("isn't on this computer"))
        #expect(recorder.execs.first?.contains("maipa-g-checkout-present") == true)
    }

    @Test("Sprites' control bytes and the .bashrc warnings are taken out of command output")
    func shellNoiseIsRemoved() {
        let raw = "\u{2}/home/sprite/.bashrc: line 22: bind: warning: line editing not enabled\n\u{2}/home/sprite/.bashrc: line 23: bind: warning: line editing not enabled\n\u{1}hello\n\u{2}cd: nowhere: No such file or directory\n\u{3}\u{1}"
        let clean = ComputerControl.withoutShellNoise(raw)
        #expect(clean == "hello\ncd: nowhere: No such file or directory\n(exit code 1)")
        #expect(ComputerControl.withoutShellNoise("\u{1}ok\n\u{3}\u{0}") == "ok")
        #expect(ComputerControl.withoutShellNoise("{\"mode\":\"644\"}") == "{\"mode\":\"644\"}")
    }
}
