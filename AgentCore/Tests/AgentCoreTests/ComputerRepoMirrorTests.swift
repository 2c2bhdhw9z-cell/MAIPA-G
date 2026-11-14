import Foundation
import Testing
@testable import AgentCore

/// One copy of the repo, like Kiro's one folder (owner, 14 November 2026: the AI "read and edited
/// the same two files" over and over). The file tools and the computer's checkout used to be two
/// copies that only met through sync_staged_to_computer, which reset the computer's copy. These
/// run the real shell and real git, as the runner on the chat computer does.
// Real shell commands hang on GitHub's Mac (see Build174Tests), so these run in the Linux job,
// which is also the system the chat computer and its runner use.
#if os(Linux)
private let onLinux = true
#else
private let onLinux = false
#endif

@Suite("Staged files and the computer's checkout are one copy", .enabled(if: onLinux))
struct ComputerRepoMirrorTests {
    struct Repo {
        let base: RepoWorkspace
        let changes: ChangeWorkspace
        let home: URL
        let control: ComputerControl
        let commit: String
        let tools: [String: any AgentTool]
        let mirror: ComputerRepoMirror
        var folder: URL { home.appendingPathComponent("repos/octo/demo") }

        func file(_ path: String) throws -> String { try String(contentsOf: folder.appendingPathComponent(path), encoding: .utf8) }
        func staged(_ path: String) async -> String? { await changes.stagedData(for: path).flatMap { String(data: $0, encoding: .utf8) } }
        func run(_ name: String, _ arguments: JSONValue) async throws -> ToolOutput {
            try await #require(tools[name]).runApproved(arguments: arguments, progress: { _ in })
        }
    }

    static let files: [String: String] = [
        "app.js": "export const version = 'v1';\n",
        "test.sh": "#!/bin/sh\ngrep -q \"'v2'\" app.js && echo TESTS-PASS || { echo TESTS-FAIL; exit 1; }\n",
        "README.md": "# Demo\n",
        "package.json": "{\"name\":\"demo\"}\n",
    ]

    @discardableResult
    static func git(_ arguments: [String], in folder: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-c", "user.name=Test", "-c", "user.email=test@localhost"] + arguments
        process.currentDirectoryURL = folder
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    static func repo(deletionAllowed: Bool = false) async throws -> Repo {
        let github = FakeGitHub()
        github.commitRemotely(files.mapValues { Optional(Data($0.utf8)) })
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("maipag-mirror-\(UUID().uuidString)", isDirectory: true)
        let folder = home.appendingPathComponent("repos/octo/demo", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (path, text) in files { try Data(text.utf8).write(to: folder.appendingPathComponent(path)) }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.appendingPathComponent("test.sh").path)
        try git(["init", "--quiet"], in: folder)
        try git(["add", "-A"], in: folder)
        try git(["commit", "--quiet", "-m", "start"], in: folder)
        let commit = try git(["rev-parse", "HEAD"], in: folder)
        // FakeGitHub answers for this one repo name; the checkout's folder name doesn't matter.
        let base = RepoWorkspace(repo: RepoRef(owner: "octo", name: "MAIPA-G-data"), branch: "main", commit: try #require(github.head), github: github.client, store: SnapshotStore(root: home.appendingPathComponent(".snapshots")))
        let changes = ChangeWorkspace(base: base)
        let control = ComputerControl.local(machine: "test", home: home)
        let authorization = ChangeAuthorization(deletion: deletionAllowed, buildSetup: false)
        let mirror = ComputerRepoMirror(control: control, workspace: changes, homePath: "repos/octo/demo", commit: commit, gate: ComputerRepoMirror.gate(authorization: authorization, rules: RepoWriteRules()))
        let raw: [any AgentTool] = [
            ReadFileTool(workspace: base, changes: changes),
            EditFileTool(workspace: changes, authorization: authorization),
            CreateFileTool(workspace: changes, authorization: authorization),
            RunCommandTool(control: control, homePath: "repos/octo/demo"),
            SyncStagedToComputerTool(control: control, workspace: changes, homePath: "repos/octo/demo", cloneURL: nil, commit: commit),
        ]
        let wrapped = ComputerMirroredTool.wrap(raw, mirror: mirror)
        return Repo(base: base, changes: changes, home: home, control: control, commit: commit, tools: Dictionary(uniqueKeysWithValues: wrapped.map { ($0.name, $0) }), mirror: mirror)
    }

    @Test("An edit is on the computer at once, so the test run right after it sees it")
    func editsReachTestsAtOnce() async throws {
        let repo = try await Self.repo()
        defer { try? FileManager.default.removeItem(at: repo.home) }
        #expect(await repo.mirror.start() == nil)
        // The old sync tool is gone: there is nothing to remember to call.
        #expect(repo.tools["sync_staged_to_computer"] == nil)
        _ = try await repo.run("edit_file", ["path": "app.js", "old_text": "'v1'", "new_text": "'v2'"])
        #expect(try repo.file("app.js") == "export const version = 'v2';\n")
        let tests = try await repo.run("run_command", ["command": "sh test.sh"])
        #expect(tests.forModel.contains("TESTS-PASS"))
        // Nothing changed on the computer by the test itself, so no note is added.
        #expect(!tests.forModel.contains("[MAIPA-G: repo files"))
    }

    @Test("What a command changes comes back, so read_file and edit_file see the computer's text")
    func commandChangesComeBack() async throws {
        let repo = try await Self.repo()
        defer { try? FileManager.default.removeItem(at: repo.home) }
        await repo.mirror.start()
        // printf, not `sed -i`: these tests also run on GitHub's Mac, whose sed takes -i differently.
        let output = try await repo.run("run_command", ["command": "printf \"export const version = 'v3';\\n\" > app.js && printf 'notes\\n' > notes.md"])
        #expect(output.forModel.contains("now staged as changed on the computer: app.js, notes.md"))
        #expect(await repo.staged("app.js") == "export const version = 'v3';\n")
        #expect(await repo.staged("notes.md") == "notes\n")
        let read = try await repo.run("read_file", ["path": "app.js"])
        #expect(read.forModel.contains("'v3'"))
        // The edit that used to fail with "old_text was not found" now finds the computer's text.
        let edit = try await repo.run("edit_file", ["path": "app.js", "old_text": "'v3'", "new_text": "'v2'"])
        #expect(!edit.isError)
        #expect(try repo.file("app.js") == "export const version = 'v2';\n")
        #expect(try await repo.run("run_command", ["command": "sh test.sh"]).forModel.contains("TESTS-PASS"))
    }

    @Test("Putting a file back to the repo's version on the computer unstages it")
    func revertUnstages() async throws {
        let repo = try await Self.repo()
        defer { try? FileManager.default.removeItem(at: repo.home) }
        await repo.mirror.start()
        _ = try await repo.run("edit_file", ["path": "app.js", "old_text": "'v1'", "new_text": "'v2'"])
        #expect(await repo.changes.stagedChange(for: "app.js") != nil)
        let output = try await repo.run("run_command", ["command": "git checkout -- app.js"])
        #expect(output.forModel.contains("back to the repo's version: app.js"))
        #expect(await repo.changes.stagedChange(for: "app.js") == nil)
    }

    @Test("Deletions and build setup keep the file tools' rules; junk, big and secret files stay on the computer")
    func safetyRulesStillApply() async throws {
        let repo = try await Self.repo()
        defer { try? FileManager.default.removeItem(at: repo.home) }
        await repo.mirror.start()
        let output = try await repo.run("run_command", ["command": "rm README.md && printf '{\"name\":\"x\"}\\n' > package.json && mkdir -p node_modules/x && echo hi > node_modules/x/a.js && echo SECRET=1 > .env && echo ok"])
        #expect(output.forModel.contains("README.md (deleted there; delete_file asks first)"))
        #expect(output.forModel.contains("package.json (build setup; edit_file asks first)"))
        #expect(output.forModel.contains("left on the computer only (they look like secrets): .env"))
        let staged = await repo.changes.stagedChanges().map(\.path)
        #expect(staged.isEmpty)
        let allowed = try await Self.repo(deletionAllowed: true)
        defer { try? FileManager.default.removeItem(at: allowed.home) }
        await allowed.mirror.start()
        _ = try await allowed.run("run_command", ["command": "rm README.md"])
        guard case .delete? = await allowed.changes.stagedChange(for: "README.md") else {
            Issue.record("An allowed deletion should be staged")
            return
        }
    }

    @Test("Writing keeps a script executable, and the next reply's start doesn't stash the work")
    func modeKeptAndNoStash() async throws {
        let repo = try await Self.repo()
        defer { try? FileManager.default.removeItem(at: repo.home) }
        await repo.mirror.start()
        _ = try await repo.run("edit_file", ["path": "test.sh", "old_text": "TESTS-PASS", "new_text": "TESTS-PASS!"])
        #expect(FileManager.default.isExecutableFile(atPath: repo.folder.appendingPathComponent("test.sh").path))
        _ = try await repo.run("run_command", ["command": "printf 'more\\n' >> README.md"])
        // The next reply starts its own copy from the same staged files.
        let next = ComputerRepoMirror(control: repo.control, workspace: repo.changes, homePath: "repos/octo/demo", commit: repo.commit, gate: { _, _ in true })
        #expect(await next.start() == nil)
        #expect(try Self.git(["stash", "list"], in: repo.folder).isEmpty)
        #expect(try repo.file("README.md") == "# Demo\nmore\n")
        #expect(try repo.file("test.sh").contains("TESTS-PASS!"))
    }
}
