import Foundation
import Testing
@testable import AgentCore

/// The AI's tools behave like Kiro's (owner: "Tools like how you do… Don't decrease/reduce or
/// remove something to make it better"): every change here adds a capability.
@Suite("Kiro tool parity")
struct ToolParityTests {
    // Real shell commands hang on GitHub's Mac (see Build174Tests); these run in the Linux job.
    #if os(Linux)
    static let onLinux = true
    #else
    static let onLinux = false
    #endif

    static func temporaryFolder(_ name: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("maipag-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    static func workspace(_ files: [String: Data]) throws -> (base: RepoWorkspace, changes: ChangeWorkspace, root: URL) {
        let github = FakeGitHub()
        github.commitRemotely(files.mapValues { Optional($0) })
        let root = try temporaryFolder("parity-repo")
        let base = RepoWorkspace(repo: RepoRef(owner: "octo", name: "MAIPA-G-data"), branch: "main", commit: try #require(github.head), github: github.client, store: SnapshotStore(root: root))
        return (base, ChangeWorkspace(base: base), root)
    }

    static func numbered(_ count: Int, width: Int = 0) -> String {
        (1...count).map { "line \($0)" + String(repeating: "x", count: width) }.joined(separator: "\n") + "\n"
    }

    // MARK: 1. Tool results: head and tail, the whole output saved

    @Test("A result over the limit keeps its start and end, saves the whole output, and read_file reads the cut part")
    func longResultsAreSavedAndReadable() async throws {
        let home = try Self.temporaryFolder("parity-home")
        defer { try? FileManager.default.removeItem(at: home) }
        let saver = DirectoryToolOutputSaver.computer(home: home)
        let text = (1...20_000).map { "line \($0)" }.joined(separator: "\n")
        let transport = ScriptedTransport([
            .events([AgentLoopTests.toolCall(id: "call_big_1", name: "big_output", arguments: "{}"), AgentLoopTests.toolsDone]),
            .events([AgentLoopTests.text("Done"), AgentLoopTests.done]),
        ])
        let (turn, _) = await ToolOutputArchive.$saver.withValue(saver) {
            await AgentLoopTests.runToEnd(transport, chat: AgentLoopTests.newChat("Run it"), route: AgentLoopTests.route(), tools: [BigOutputTool(text: text)])
        }
        let call = try #require(turn?.steps.first?.toolCalls.first)
        let result = try #require(call.result)
        #expect(result.hasPrefix("line 1\nline 2\n"))
        #expect(result.hasSuffix("line 19999\nline 20000"))
        #expect(result.contains("characters cut from the middle; full output saved to ~/.maipa-g/outputs/call_big_1.txt"))
        #expect(result.contains("read_file using offset/limit"))
        #expect(Transcript.wrapToolResult(result, tool: "big_output").count <= Transcript.maxToolResultCharacters)
        let saved = try String(contentsOf: home.appendingPathComponent(".maipa-g/outputs/call_big_1.txt"), encoding: .utf8)
        #expect(saved == text)

        let (base, changes, root) = try Self.workspace(["README.md": Data("hi\n".utf8)])
        defer { try? FileManager.default.removeItem(at: root) }
        let read = try await ToolOutputArchive.$saver.withValue(saver) {
            try await ReadFileTool(workspace: base, changes: changes).run(arguments: ["path": "~/.maipa-g/outputs/call_big_1.txt", "offset": 9_999, "limit": 2]) { _ in }
        }
        #expect(read.forModel.contains("10000\tline 10000"))
        #expect(read.forModel.contains("10001\tline 10001"))
        #expect(!read.forModel.contains("\tline 10002"))
        #expect(read.forModel.contains("Read on with offset 10001"))
        await #expect(throws: ToolInputError.self) {
            _ = try await ReadFileTool(workspace: base, changes: changes).run(arguments: ["path": "~/.maipa-g/outputs/gone.txt"]) { _ in }
        }
    }

    @Test("Cutting a cut result again keeps its marker and saved path; without a saver the marker says so")
    func markerSurvivesRecapping() throws {
        let original = String(repeating: "a", count: 25_000) + String(repeating: "b", count: 25_000)
        let capped = Transcript.cappedToolResult(original, savedTo: "~/.maipa-g/outputs/x.txt", readHint: nil)
        #expect(capped.count <= Transcript.maxToolResultCharacters && capped.count >= Transcript.maxToolResultCharacters - 1)
        #expect(capped.hasPrefix("aaaa") && capped.hasSuffix("bbbb"))
        let smaller = Transcript.cappedToolResult(capped, limit: 10_000)
        #expect(smaller.count <= 10_000 && smaller.count >= 9_999)
        #expect(smaller.contains("full output saved to ~/.maipa-g/outputs/x.txt"))
        #expect(smaller.components(separatedBy: "characters cut from the middle").count == 2)
        #expect(smaller.hasPrefix("aaaa") && smaller.hasSuffix("bbbb"))
        let marker = try #require(smaller.range(of: #"\[\.\.\. [0-9]+ characters"#, options: .regularExpression))
        let cut = Int(smaller[marker].filter(\.isNumber)) ?? 0
        let markerText = try #require(smaller.range(of: #"\n\n\[\.\.\. [^\n]* \.\.\.\]\n\n"#, options: .regularExpression))
        #expect(cut + smaller.count - smaller[markerText].count == original.count)

        let unsaved = Transcript.cappedToolResult(original)
        #expect(unsaved.contains("The full output wasn't saved"))

        // Under the limit, but over it once JSON-escaped: still cut with the saved path named.
        let quotes = String(repeating: "\"", count: 20_000)
        var asked = 0
        let fitted = Transcript.fittedToolResult(quotes, tool: "t") {
            asked += 1
            return ("~/.maipa-g/outputs/q.txt", "read it with read_file")
        }
        #expect(asked == 1)
        #expect(fitted.contains("full output saved to ~/.maipa-g/outputs/q.txt"))
        #expect(Transcript.wrapToolResult(fitted, tool: "t").count <= Transcript.maxToolResultCharacters)
        #expect(Transcript.fittedToolResult("small", tool: "t") { Issue.record("no save for small results"); return nil } == "small")
        #expect(ToolOutputArchive.fileName(for: "call_1/../x") == "call_1x.txt")
        #expect(ToolOutputArchive.fileName(for: "1").hasPrefix("1-"))
    }

    @Test("The saver's folder is kept to a number of files")
    func saverPrunesOldOutputs() throws {
        let folder = try Self.temporaryFolder("parity-outputs")
        defer { try? FileManager.default.removeItem(at: folder) }
        let saver = DirectoryToolOutputSaver(directory: folder, keep: 3)
        for index in 1...5 { #expect(saver.save("output \(index)", callID: "call_\(index)_abc", tool: "t") == "~/.maipa-g/outputs/call_\(index)_abc.txt") }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).count == 3)
        #expect(saver.savedText(at: "~/.maipa-g/outputs/call_5_abc.txt") == "output 5")
        #expect(saver.savedText(at: "~/.maipa-g/outputs/../secret") == nil)
        #expect(saver.savedText(at: "README.md") == nil)
    }

    // MARK: 3. read_file

    @Test("read_file takes offset/limit as well as start_line/end_line, always ends with its footer, and says when a start is past the end")
    func readFileRanges() async throws {
        let (base, changes, root) = try Self.workspace(["ten.txt": Data(Self.numbered(10).utf8), "big.txt": Data(Self.numbered(3_000, width: 90).utf8)])
        defer { try? FileManager.default.removeItem(at: root) }
        let tool = ReadFileTool(workspace: base, changes: changes)
        let part = try await tool.run(arguments: ["path": "ten.txt", "offset": 2, "limit": 3]) { _ in }
        #expect(part.forModel.contains("     3\tline 3") && part.forModel.contains("     5\tline 5") && !part.forModel.contains("\tline 6"))
        #expect(part.forModel.hasSuffix("(Lines 3-5 of 10. 5 more lines. Read on with offset 5 (start_line 6).)"))
        let same = try await tool.run(arguments: ["path": "ten.txt", "start_line": 3, "end_line": 5]) { _ in }
        #expect(same.forModel == part.forModel)
        let end = try await tool.run(arguments: ["path": "ten.txt", "start_line": 9]) { _ in }
        #expect(end.forModel.hasSuffix("(Lines 9-10 of 10.)"))
        do {
            _ = try await tool.run(arguments: ["path": "ten.txt", "start_line": 11]) { _ in }
            Issue.record("A start past the end should be an error")
        } catch let error as ToolInputError {
            #expect(error.message.contains("has 10 lines"))
        }

        // A read bigger than the tool-result limit stops early, whole, with its footer intact.
        let big = try await tool.run(arguments: ["path": "big.txt"]) { _ in }
        #expect(Transcript.wrapToolResult(big.forModel, tool: "read_file").count <= Transcript.maxToolResultCharacters)
        #expect(Transcript.fittedToolResult(big.forModel, tool: "read_file") == big.forModel)
        #expect(big.forModel.contains("Stopped here to stay within the size of one read."))
        #expect(big.forModel.range(of: #"Read on with offset [0-9]+ \(start_line [0-9]+\)\.\)$"#, options: .regularExpression) != nil)
    }

    @Test("A file over 2 MB is read in ranges instead of being refused")
    func largeFilesAreReadInRanges() async throws {
        let text = Self.numbered(30_000, width: 80)
        #expect(text.utf8.count > SnapshotStore.maxStoredFileSize)
        let (base, changes, root) = try Self.workspace(["huge.log": Data(text.utf8)])
        defer { try? FileManager.default.removeItem(at: root) }
        let read = try await ReadFileTool(workspace: base, changes: changes).run(arguments: ["path": "huge.log", "offset": 25_000, "limit": 2]) { _ in }
        #expect(read.forModel.contains("large file: read it in ranges with offset and limit"))
        #expect(read.forModel.contains(" 25001\tline 25001"))
        #expect(read.forModel.contains(" 25002\tline 25002"))
        #expect(!read.forModel.contains("search_code"))
    }

    // MARK: 4. search_code

    @Test("search_code keeps indentation, shows context lines with numbers, leaves out excluded folders and caps per file")
    func searchContextAndExclusions() async throws {
        let (snapshot, _, root) = try RepoCopyTests.unpackFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = "struct A {\n    func one() {\n        let needle = 1\n    }\n}\n// gap\n// gap\n// gap\nlet needle2 = \"" + String(repeating: "z", count: 900) + "\"\n"
        let staged: [StagedChange] = [
            .write(path: "Sources/A.swift", data: Data(source.utf8), existed: false),
            .write(path: "build/Gen.swift", data: Data("let needle = 2\n".utf8), existed: false),
            .write(path: "Many.swift", data: Data(String(repeating: "needle\n", count: 5).utf8), existed: false),
        ]
        let query = SearchQuery(pattern: "needle", maxResults: 100, maxPerFile: 2, contextLines: 2, excludeGlob: "build")
        let result = try await CodeSearch.run(query, in: snapshot, stagedChanges: staged)
        #expect(!result.matches.contains { $0.path.hasPrefix("build/") })
        #expect(result.matches.filter { $0.path == "Many.swift" }.count == 2 && result.truncated)
        let first = try #require(result.matches.first { $0.path == "Sources/A.swift" && $0.line == 3 })
        #expect(first.text == "        let needle = 1")
        #expect(first.contextBefore.map(\.line) == [1, 2] && first.contextAfter.map(\.line) == [4, 5])
        let long = try #require(result.matches.first { $0.path == "Sources/A.swift" && $0.line == 9 })
        #expect(long.text.hasSuffix("[truncated: line too long]"))
        let lines = SearchCodeTool.render(result, query: query)
        #expect(lines.contains("  3:         let needle = 1"))
        #expect(lines.contains("  2-     func one() {"))
        #expect(lines.contains("  --"))
        #expect(lines.filter { $0 == "  7- // gap" }.count == 1)
        #expect(CodeSearch.isExcluded("a/node_modules/x/y.js", by: Glob("node_modules")))
        #expect(!CodeSearch.isExcluded("src/modules.js", by: Glob("node_modules")))
        #expect(SearchCodeTool.defaultResults == 100)
    }

    // MARK: 5. file_search

    @Test("file_search matches part of a path, anchors with ^ and $, leaves out excluded folders, shows close matches, at most 10")
    func fileSearchRanking() async throws {
        let paths = ["App/Sources/Model/ChatSession.swift", "App/Sources/Screens/ChatScreen.swift", "AgentCore/Sources/AgentCore/Agent/AgentLoop.swift", "README.md", "node_modules/chat/index.js"]
        #expect(FileSearch.rank("chatsession", in: paths).matches.first?.path == "App/Sources/Model/ChatSession.swift")
        #expect(FileSearch.rank("^App/", in: paths).matches.map(\.path).allSatisfy { $0.hasPrefix("App/") })
        #expect(FileSearch.rank(".swift$", in: paths).total == 3)
        #expect(FileSearch.rank("^README.md$", in: paths).matches.map(\.path) == ["README.md"])
        #expect(!FileSearch.rank("chat", in: paths, exclude: Glob("node_modules")).matches.contains { $0.path.hasPrefix("node_modules") })
        let close = FileSearch.rank("agntlp", in: paths)
        #expect(close.matches.first?.path.hasSuffix("AgentLoop.swift") == true && close.matches.first?.isClose == true)
        let many = (1...30).map { "Sources/File\($0).swift" }
        let capped = FileSearch.rank("file", in: many)
        #expect(capped.matches.count == 10 && capped.total == 30)

        let (base, changes, root) = try Self.workspace(["App/Sources/Main.swift": Data("x\n".utf8), "Docs/Guide.md": Data("y\n".utf8)])
        defer { try? FileManager.default.removeItem(at: root) }
        try await changes.create(path: "App/Sources/NewThing.swift", text: "z\n")
        let tool = FileSearchTool(workspace: base, changes: changes)
        let found = try await tool.run(arguments: ["query": "newthing"]) { _ in }
        #expect(found.forModel.contains("App/Sources/NewThing.swift"))
        let none = try await tool.run(arguments: ["query": "^zzz"]) { _ in }
        #expect(none.forModel.contains("No file path matches"))
        #expect(BuiltInAgents.inspectToolNames.contains("file_search"))
    }

    // MARK: 2. run_command

    @Test("run_command puts the exit code first, runs in any existing folder, refuses a missing one, and stops at timeout_seconds", .enabled(if: ToolParityTests.onLinux))
    func runCommandLikeKiro() async throws {
        let home = try Self.temporaryFolder("parity-run")
        defer { try? FileManager.default.removeItem(at: home) }
        let control = ComputerControl.local(machine: "test-machine", home: home)
        let tool = RunCommandTool(control: control, homePath: nil)
        let ok = try await tool.runApproved(arguments: ["command": "echo hello"]) { _ in }
        #expect(ok.forModel == "Exit code: 0\nhello")
        let failing = try await tool.runApproved(arguments: ["command": "echo oops >&2; exit 3"]) { _ in }
        #expect(failing.forModel.hasPrefix("Exit code: 3\n") && failing.forModel.contains("oops") && !failing.forModel.contains("(exit code 3)"))
        #expect(failing.summary.hasPrefix("Failed: "))

        let folder = home.appendingPathComponent("work dir", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let absolute = try await tool.runApproved(arguments: ["command": "pwd", "cwd": .string(folder.path)]) { _ in }
        #expect(absolute.forModel.hasSuffix("/work dir"))
        let relative = try await tool.runApproved(arguments: ["command": "pwd", "working_directory": "work dir"]) { _ in }
        #expect(relative.forModel.hasSuffix("/work dir"))
        do {
            _ = try await tool.runApproved(arguments: ["command": "pwd", "cwd": "/definitely/not/here"]) { _ in }
            Issue.record("A missing cwd should be an error")
        } catch let error as ToolInputError {
            #expect(error.message.contains("/definitely/not/here doesn't exist"))
        }

        let slow = try await tool.runApproved(arguments: ["command": "sleep 5; echo late", "timeout_seconds": 1]) { _ in }
        #expect(!slow.forModel.hasPrefix("Exit code: 0"))
        #expect(slow.forModel.contains("Stopped after 1 second"))
        #expect(!slow.forModel.contains("late"))
        #expect(RunCommandTool.timeoutSeconds(["timeout_seconds": 99_999]) == 1_800)
        #expect(RunCommandTool.timeoutSeconds([:]) == 900)
        #expect(BoundedProcess.maxTimeout == 1_800)
        let properties = tool.spec.function.parameters["properties"]?.objectValue ?? [:]
        #expect(["command", "cwd", "working_directory", "timeout_seconds", "run_in_background"].allSatisfy { properties[$0] != nil })
        #expect(!tool.spec.function.description.contains("longer than 2 minutes"))
    }

    @Test("run_command can start a command in the background and hand back its task", .enabled(if: ToolParityTests.onLinux))
    func runCommandInBackground() async throws {
        let home = try Self.temporaryFolder("parity-bg")
        defer { try? FileManager.default.removeItem(at: home) }
        let control = ComputerControl.local(machine: "test-machine", home: home)
        let tool = RunCommandTool(control: control, homePath: nil)
        let started = try await tool.runApproved(arguments: ["command": "echo background-done", "run_in_background": true]) { _ in }
        let range = try #require(started.forModel.range(of: #"task-[a-z0-9]+"#, options: .regularExpression))
        let id = String(started.forModel[range])
        #expect(started.forModel.contains("~/.maipa-g/tasks/\(id).log"))
        var status = ""
        for _ in 0..<100 {
            status = try await control.backgroundStatus(id)
            if status.hasPrefix("finished") { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        #expect(status.hasPrefix("finished: maipa-g-exit 0"))
        #expect(status.contains("background-done"))
        await #expect(throws: ToolInputError.self) {
            _ = try await tool.runApproved(arguments: ["command": "true", "run_in_background": true, "cwd": "/nope/nope"]) { _ in }
        }
    }

    @Test("A command tool without a time-limit setting gets the limit from the shell; the local one takes it directly")
    func timeoutsReachEveryComputer() async throws {
        let recorder = LineRecorder()
        let execTool = ConnectorToolDefinition(serverID: "s", serverName: "Sprites", originalName: "exec", description: "", inputSchema: ["type": "object", "properties": ["cmd": ["type": "array", "items": ["type": "string"]]]])
        let control = ComputerControl(tools: [execTool], machine: "m") { _, arguments in
            recorder.exec(arguments["cmd"]?.arrayValue?.compactMap(\.stringValue).last ?? "")
            return ("done", false)
        }
        _ = try await control.run("make test", timeout: 300)
        #expect(recorder.execs.last?.contains("timeout -k 10 300 bash -c") == true)
        _ = try await control.run("make test")
        #expect(recorder.execs.last == "make test")
        let local = ComputerControl.local(machine: "m", home: FileManager.default.temporaryDirectory)
        let localTool = try #require(local.commandTool)
        #expect(ComputerControl.timeoutKey(localTool.inputSchema)?.key == "timeout_seconds")
        #expect(local.commandArguments("ls", tool: localTool, timeout: 42)["timeout_seconds"]?.intValue == 42)
        #expect(!ComputerControl.Failure.commandFailed(String(repeating: "e", count: 2_000)).description.hasSuffix("e…"))
        #expect(ComputerControl.Failure.commandFailed(String(repeating: "e", count: 2_000)).description.count > 2_000)
    }

    @Test("Long commands report progress, so they never look like a tool that went quiet")
    func heartbeatReportsProgress() async throws {
        let beats = LineRecorder()
        let value = try await RunCommandTool.withHeartbeat("Running make", progress: { beats.exec($0) }, every: 1) {
            // Wait for a beat instead of a fixed time, so a busy test machine can't race it.
            for _ in 0..<600 where beats.execs.isEmpty { try await Task.sleep(nanoseconds: 50_000_000) }
            return 7
        }
        #expect(value == 7)
        #expect(beats.execs.first?.hasPrefix("Running make · ") == true)
    }

    // MARK: 8. list_files on the computer

    @Test("list_files can list the real checkout on the computer", .enabled(if: ToolParityTests.onLinux))
    func listFilesOnComputer() async throws {
        let home = try Self.temporaryFolder("parity-list")
        defer { try? FileManager.default.removeItem(at: home) }
        let checkout = home.appendingPathComponent("repos/octo/app", isDirectory: true)
        for file in ["src/main.swift", "build/out.o", ".git/HEAD"] {
            let url = checkout.appendingPathComponent(file)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url)
        }
        let (base, changes, root) = try Self.workspace(["README.md": Data("hi\n".utf8)])
        defer { try? FileManager.default.removeItem(at: root) }
        let control = ComputerControl.local(machine: "test-machine", home: home)
        let tool = ListFilesTool(workspace: base, changes: changes, computer: control, computerPath: "repos/octo/app")
        let tree = try await tool.run(arguments: ["on_computer": true]) { _ in }
        #expect(tree.forModel.contains("~/repos/octo/app on test-machine"))
        #expect(tree.forModel.contains("src/\n  main.swift") && tree.forModel.contains("build/"))
        #expect(!tree.forModel.contains("HEAD") && !tree.forModel.contains("README.md"))
        let found = try await tool.run(arguments: ["where": "computer", "pattern": "*.swift"]) { _ in }
        #expect(found.forModel.contains("src/main.swift") && !found.forModel.contains("out.o"))
        await #expect(throws: ToolInputError.self) { _ = try await tool.run(arguments: ["on_computer": true, "path": "missing"]) { _ in } }
        await #expect(throws: ToolInputError.self) { _ = try await ListFilesTool(workspace: base, changes: changes).run(arguments: ["on_computer": true]) { _ in } }
        let repo = try await tool.run(arguments: [:]) { _ in }
        #expect(repo.forModel.contains("README.md"))
    }

    // MARK: 9. code (ast-grep)

    @Test("The code tool builds ast-grep runs, dry-runs rewrites unless apply is true, and says how to install ast-grep")
    func codeToolUsesAstGrep() async throws {
        let search = try CodeTool.commandLine(["operation": "pattern_search", "pattern": "console.log($ARG)", "language": "ts", "path": "src", "context_lines": 2])
        #expect(search.contains("--pattern 'console.log($ARG)'") && search.contains("--lang 'ts'") && search.contains("--context 2") && search.hasSuffix("-- 'src'"))
        let dryRun = try CodeTool.commandLine(["operation": "pattern_rewrite", "pattern": "a", "rewrite": "b"])
        #expect(dryRun.contains("--rewrite 'b'") && !dryRun.contains("--update-all"))
        let apply = try CodeTool.commandLine(["operation": "pattern_rewrite", "pattern": "a", "rewrite": "b", "apply": true])
        #expect(apply.contains("--update-all"))
        #expect(throws: ToolInputError.self) { _ = try CodeTool.commandLine(["operation": "pattern_rewrite", "pattern": "a"]) }
        #expect(throws: ToolInputError.self) { _ = try CodeTool.commandLine(["operation": "explode", "pattern": "a"]) }
        // Linux's own `sg` (switch group) is not ast-grep.
        #expect(CodeTool.findAstGrep.contains("grep -qi 'ast-grep'"))

        let missing = ComputerControl(tools: [ConnectorToolDefinition(serverID: "s", serverName: "S", originalName: "exec", description: "", inputSchema: ["type": "object", "properties": ["cmd": ["type": "array", "items": ["type": "string"]]]])], machine: "m") { _, _ in
            (CodeTool.notInstalledMarker, false)
        }
        do {
            _ = try await CodeTool(control: missing, homePath: "repos/o/r").run(arguments: ["operation": "pattern_search", "pattern": "a"]) { _ in }
            Issue.record("A missing ast-grep should be explained")
        } catch let error as ToolInputError {
            #expect(error.message.contains("npm i -g @ast-grep/cli") && error.message.contains("brew install ast-grep"))
        }
        let found = ComputerControl(tools: missing.tools, machine: "m") { _, _ in ("src/a.ts:3:console.log(x)", false) }
        let output = try await CodeTool(control: found, homePath: nil).run(arguments: ["operation": "pattern_rewrite", "pattern": "console.log($A)", "rewrite": "log($A)"]) { _ in }
        #expect(output.forModel.hasPrefix("Dry run") && output.forModel.contains("src/a.ts:3"))
        #expect(AgentDefinition.mutatingTools.contains("code"))
    }

    // MARK: 6. Writing files

    @Test("create_file can overwrite when asked, edits say when whitespace was ignored, append starts a new line, and binary files can be deleted")
    func writeSemantics() async throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, 0xFF, 0x00])
        let (_, changes, root) = try Self.workspace([
            "a.swift": Data("func a() {\n    let x = 1\n}\n".utf8),
            "notes.txt": Data("abc".utf8),
            "logo.png": png,
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let create = CreateFileTool(workspace: changes)
        do {
            _ = try await create.run(arguments: ["path": "a.swift", "content": "new"]) { _ in }
            Issue.record("An existing file should need overwrite")
        } catch let error as ChangeWorkspaceError {
            #expect(error.description.contains("overwrite: true") && error.description.contains("edit_file"))
        }
        let replaced = try await create.run(arguments: ["path": "a.swift", "content": "let y = 2\n", "overwrite": true]) { _ in }
        #expect(replaced.forModel.contains("Replaced the whole of a.swift"))
        guard case .text(let text, _) = try await changes.read("a.swift") else { Issue.record("a.swift should be text"); return }
        #expect(text == "let y = 2\n")
        #expect(create.spec.function.parameters["properties"]?["overwrite"] != nil)

        try await changes.edit(path: "a.swift", text: "func a() {\n    let x = 1\n}\n")
        let edit = try await EditFileTool(workspace: changes).run(arguments: ["path": "a.swift", "old_text": "func a() {\n  let x = 1\n}", "new_text": "func a() {\n    let x = 2\n}"]) { _ in }
        #expect(edit.forModel.contains("whitespace-tolerant match") && edit.forModel.contains("lines 1-3"))
        let exact = try await EditFileTool(workspace: changes).run(arguments: ["path": "a.swift", "old_text": "let x = 2", "new_text": "let x = 3"]) { _ in }
        #expect(!exact.forModel.contains("whitespace-tolerant"))

        let append = try await AppendFileTool(workspace: changes).run(arguments: ["path": "notes.txt", "content": "def\n"]) { _ in }
        #expect(append.forModel.contains("didn't end with a line break, so one was added"))
        guard case .text(let notes, _) = try await changes.read("notes.txt") else { Issue.record("notes.txt should be text"); return }
        #expect(notes == "abc\ndef\n")
        let again = try await AppendFileTool(workspace: changes).run(arguments: ["path": "notes.txt", "content": "ghi"]) { _ in }
        #expect(!again.forModel.contains("so one was added"))

        _ = try await DeleteFileTool(workspace: changes).runApproved(arguments: ["path": "logo.png"]) { _ in }
        #expect(await changes.stagedChanges().contains { if case .delete("logo.png", let previous) = $0 { return previous == png } else { return false } })
    }

    // MARK: 7. Web

    @Test("read_web_page reads the first part, the whole page, or only the parts about a phrase, and says what was left out")
    func readWebPageModes() async throws {
        let filler = (1...700).map { "Paragraph \($0) says nothing in particular about anything at all." }.joined(separator: "</p><p>")
        let html = "<html><head><title>Docs</title></head><body><p>\(filler)</p><p>The rate limit is 60 requests per minute.</p><p>The end.</p></body></html>"
        let transport = PageTransport { _ in HTTPResponse(status: 200, headers: ["content-type": "text/html"], body: Data(html.utf8)) }
        let tool = ReadWebPageTool(transport: transport)
        let first = try await tool.run(arguments: ["url": "https://example.com/docs"]) { _ in }
        #expect(first.forModel.contains("[Showing the first 30000 of"))
        #expect(!first.forModel.contains("The end."))
        let full = try await tool.run(arguments: ["url": "https://example.com/docs", "mode": "full"]) { _ in }
        #expect(full.forModel.contains("The end.") && !full.forModel.contains("[Showing the first"))
        let selective = try await tool.run(arguments: ["url": "https://example.com/docs", "mode": "selective", "search_phrase": "RATE LIMIT"]) { _ in }
        #expect(selective.forModel.contains("60 requests per minute") && !selective.forModel.contains("Paragraph 1 says"))
        #expect(selective.forModel.contains("Only the parts of the page that mention"))
        let nothing = try await tool.run(arguments: ["url": "https://example.com/docs", "mode": "selective", "search_phrase": "kangaroo"]) { _ in }
        #expect(nothing.forModel.contains("No part of the page mentions"))
        await #expect(throws: ToolInputError.self) { _ = try await tool.run(arguments: ["url": "https://example.com/docs", "mode": "selective"]) { _ in } }
        await #expect(throws: ToolInputError.self) { _ = try await tool.run(arguments: ["url": "https://example.com/docs", "mode": "everything"]) { _ in } }
    }

    @Test("web_search refuses queries over 200 characters and tells an unreadable results page from no results")
    func webSearchErrors() async throws {
        let unreadable = WebSearchTool(transport: PageTransport { _ in HTTPResponse(status: 200, headers: ["content-type": "text/html"], body: Data("<html><body>Please verify you are human</body></html>".utf8)) })
        await #expect(throws: WebSearchError.unreadableResults) { _ = try await unreadable.run(arguments: ["query": "swift"]) { _ in } }
        let empty = WebSearchTool(transport: PageTransport { _ in HTTPResponse(status: 200, headers: ["content-type": "text/html"], body: Data("<html><body><div class=\"no-results\">No results.</div></body></html>".utf8)) })
        let none = try await empty.run(arguments: ["query": "zxqv"]) { _ in }
        #expect(none.forModel.hasPrefix("No web results found for zxqv."))
        do {
            _ = try await empty.run(arguments: ["query": .string(String(repeating: "a", count: 201))]) { _ in }
            Issue.record("A 201-character query should be refused")
        } catch let error as ToolInputError {
            #expect(error.message.contains("201 characters") && error.message.contains("200 or fewer"))
        }
    }

    // MARK: 10. invoke_sub_agent contextFiles

    @Test("invoke_sub_agent reads contextFiles into the sub-agent's first message")
    func subAgentContextFiles() async throws {
        let (base, changes, root) = try Self.workspace(["Sources/A.swift": Data(Self.numbered(20).utf8)])
        defer { try? FileManager.default.removeItem(at: root) }
        let tasks = LineRecorder()
        let definitions = SubAgentSetup.definitions(excluding: ["introspect", "custom-agent-creator"])
        let coordinator = AgentHelperCoordinator(lead: SubAgentSetup.lead, definitions: definitions, context: "", spendLimit: nil) { invocation in
            tasks.exec(invocation.task)
            return AgentExecutionResult(output: "ok", model: "m", cost: 0, toolCallCount: 0, toolSummaries: [], status: "completed")
        }
        let tool = InvokeSubAgentTool(lead: SubAgentSetup.lead, definitions: definitions, coordinator: coordinator, contextTools: [ReadFileTool(workspace: base, changes: changes)])
        let arguments: JSONValue = [
            "name": "context-gatherer", "prompt": "Explain A.", "explanation": "Reading A.",
            "contextFiles": [["path": "Sources/A.swift", "startLine": 3, "endLine": 4], ["path": "Missing.swift"]],
        ]
        _ = try await tool.runLive(arguments: arguments, callID: "c1", existingSubagents: nil) { _ in }
        let task = try #require(tasks.execs.first)
        #expect(task.contains("<context_file path=\"Sources/A.swift\" lines=\"3-4\">"))
        #expect(task.contains("     3\tline 3") && task.contains("     4\tline 4") && !task.contains("line 5\n"))
        #expect(task.contains("<context_file path=\"Missing.swift\">\n(Couldn't read it: There is no file Missing.swift."))
        #expect(task.hasSuffix("Your task:\nExplain A."))
        let schema = tool.spec.function.parameters["properties"]?["contextFiles"]
        #expect(schema?["items"]?["required"]?.arrayValue == ["path"])
        await #expect(throws: ToolInputError.self) {
            _ = try await tool.runLive(arguments: ["name": "context-gatherer", "prompt": "p", "explanation": "e", "contextFiles": "A.swift"], callID: "c2", existingSubagents: nil) { _ in }
        }
    }

    // MARK: 11. update_session_information

    @Test("update_session_information checks its fields and the app can read a finished call")
    func sessionInformation() async throws {
        let tool = UpdateSessionInformationTool()
        let output = try await tool.run(arguments: ["title": "Fix the login screen", "description": "I'm reading the login code.", "status": "waiting_on_user"]) { _ in }
        #expect(output.forModel.contains("title “Fix the login screen”") && output.forModel.contains("status waiting_on_user"))
        await #expect(throws: ToolInputError.self) { _ = try await tool.run(arguments: [:]) { _ in } }
        await #expect(throws: ToolInputError.self) { _ = try await tool.run(arguments: ["title": .string(String(repeating: "t", count: 101))]) { _ in } }
        await #expect(throws: ToolInputError.self) { _ = try await tool.run(arguments: ["description": .string(String(repeating: "d", count: 501))]) { _ in } }
        await #expect(throws: ToolInputError.self) { _ = try await tool.run(arguments: ["status": "sleeping"]) { _ in } }
        let parsed = SessionInformationUpdate.parse(arguments: #"{"title":"Ship it","status":"completed"}"#)
        #expect(parsed == SessionInformationUpdate(title: "Ship it", description: nil, status: .completed))
        #expect(SessionInformationUpdate.parse(arguments: "not json") == nil)
        #expect(SessionInformationUpdate.parse(arguments: #"{"status":"maybe"}"#) == nil)
        #expect(UpdateSessionInformationTool.toolName == "update_session_information")
        #expect(SystemPrompt.make(userLogin: nil, repo: nil).contains("`update_session_information`"))
    }

    // MARK: 12. Descriptions

    @Test("Tool descriptions say when to use them, when not to, and their limits")
    func descriptionsAreClear() throws {
        let (base, changes, root) = try Self.workspace(["README.md": Data("hi\n".utf8)])
        defer { try? FileManager.default.removeItem(at: root) }
        let control = ComputerControl.local(machine: "m", home: FileManager.default.temporaryDirectory)
        let transport = PageTransport { _ in HTTPResponse(status: 404) }
        let tools: [any AgentTool] = [
            CreateFileTool(workspace: changes), DeleteFileTool(workspace: changes), ReadFileTool(workspace: base), SearchCodeTool(workspace: base),
            FileSearchTool(workspace: base), RunCommandTool(control: control, homePath: "repos/o/r"), ComputerTaskTool(control: control, homePath: nil),
            WebSearchTool(transport: transport), ReadWebPageTool(transport: transport), CodeTool(control: control, homePath: nil),
            LiveStatusTool { "" }, UpdateSessionInformationTool(),
        ]
        for tool in tools {
            let description = tool.spec.function.description
            #expect(description.count > 200, "\(tool.name) should explain itself")
            #expect(description.contains("Don't") || description.contains("don't") || description.contains("not "), "\(tool.name) should say when not to use it")
            #expect(JSONValue.parse(tool.spec.function.parameters.jsonString()) != nil)
        }
    }
}

private struct BigOutputTool: AgentTool {
    let text: String
    let name = "big_output"
    var spec: ToolSpec { ToolSpec(name: name, description: "Test output", parameters: ["type": "object"]) }
    func runningSummary(for arguments: JSONValue) -> String { "Running…" }
    func run(arguments: JSONValue, progress: @escaping @Sendable (String) -> Void) async throws -> ToolOutput {
        ToolOutput(forModel: text, summary: "Ran", detail: String(text.prefix(100)))
    }
}

private final class PageTransport: HTTPTransport, @unchecked Sendable {
    let handler: @Sendable (HTTPRequest) -> HTTPResponse
    init(_ handler: @escaping @Sendable (HTTPRequest) -> HTTPResponse) { self.handler = handler }
    func send(_ request: HTTPRequest) async throws -> HTTPResponse { handler(request) }
    func stream(_ request: HTTPRequest) async throws -> HTTPStreamResponse {
        HTTPStreamResponse(status: 500, headers: [:], body: AsyncThrowingStream { $0.finish() })
    }
}

private final class LineRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    var execs: [String] { lock.withLock { lines } }
    func exec(_ line: String) { lock.withLock { lines.append(line) } }
}
