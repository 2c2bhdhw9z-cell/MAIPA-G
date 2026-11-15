import Foundation
import Testing
@testable import AgentCore

/// Owner, 14 November 2026: "if I tell you to save to a branch, you're gonna save to a branch". The
/// Korg chat found its work on PR #1's branch but, with the chat on main, could only open PR #2.
@Suite("Working on and saving to any branch, like git checkout")
struct BranchSwitchTests {
    #if os(Linux)
    static let onLinux = true
    #else
    static let onLinux = false
    #endif
    struct Setup {
        let github: FakeGitHub
        let root: URL
        let changes: ChangeWorkspace
        let tool: SwitchBranchTool
        let save: SaveChangesTool
        let mainHead: String
        let featureHead: String
    }

    /// main has moved on since `feature` was made from it.
    static func setup() async throws -> Setup {
        let github = FakeGitHub()
        github.commitRemotely(["README.md": Data("start\n".utf8)])
        let featureHead = try #require(github.head)
        github.branchHeads["feature"] = featureHead
        github.commitRemotely(["README.md": Data("main moved on\n".utf8), "MAIN.md": Data("only on main\n".utf8)])
        let mainHead = try #require(github.head)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("maipag-branch-\(UUID().uuidString)", isDirectory: true)
        let repo = RepoRef(owner: "octo", name: "MAIPA-G-data")
        let base = RepoWorkspace(repo: repo, branch: "main", commit: mainHead, github: github.client, store: SnapshotStore(root: root))
        let changes = ChangeWorkspace(base: base)
        let session = ChangeSession(receipts: [])
        return Setup(
            github: github, root: root, changes: changes,
            tool: SwitchBranchTool(workspace: changes, github: github.client, defaultBranch: "main"),
            save: SaveChangesTool(workspace: changes, service: GitHubChangeService(github: github.client), session: session, selectedBranch: "main", defaultBranch: "main", rules: RepoWriteRules()),
            mainHead: mainHead, featureHead: featureHead
        )
    }

    @Test("Switching to the branch the work is on, then saving, commits to that branch and leaves main alone")
    func savesOnTheBranchItSwitchedTo() async throws {
        let s = try await Self.setup()
        defer { try? FileManager.default.removeItem(at: s.root) }
        let switched = try await s.tool.run(arguments: ["branch": "feature"]) { _ in }
        #expect(switched.forModel.hasPrefix("Now on feature at \(s.featureHead.prefix(7))"))
        #expect(s.changes.base.branch == "feature" && s.changes.base.commit == s.featureHead)
        // Reads see the branch's files, not main's.
        guard case .text(let readme, _) = try await s.changes.read("README.md") else { Issue.record("README.md should be text"); return }
        #expect(readme == "start\n")
        #expect(!(await s.changes.exists("MAIN.md")))
        try await s.changes.edit(path: "README.md", text: "fixed on feature\n")
        let saved = try await s.save.runApproved(arguments: ["title": "Fix the readme"]) { _ in }
        #expect(saved.forModel.contains("pull request"))
        let commit = try #require(s.github.branchHeads["feature"])
        #expect(s.github.commits[commit]?.parent == s.featureHead)
        #expect(s.github.remoteFile("README.md") == Data("main moved on\n".utf8), "main is untouched")
        #expect(s.changes.base.branch == "feature" && s.changes.base.commit == commit)
    }

    @Test("A new branch is made from where the work is, and staged changes come along")
    func newBranchCarriesStagedChanges() async throws {
        let s = try await Self.setup()
        defer { try? FileManager.default.removeItem(at: s.root) }
        try await s.changes.edit(path: "README.md", text: "work in progress\n")
        let made = try await s.tool.run(arguments: ["branch": "korg/fixes", "create": true]) { _ in }
        #expect(made.forModel.contains("a new branch made from main") && made.forModel.contains("1 staged change came along"))
        #expect(s.github.branchHeads["korg/fixes"] == s.mainHead)
        #expect(await s.changes.stagedData(for: "README.md") == Data("work in progress\n".utf8))
        _ = try await s.save.runApproved(arguments: ["title": "WIP"]) { _ in }
        let commit = try #require(s.github.branchHeads["korg/fixes"])
        #expect(s.github.commits[commit]?.parent == s.mainHead)
        #expect(s.github.remoteFile("README.md") == Data("main moved on\n".utf8))
    }

    @Test("A branch that doesn't exist, a bad name, or creating one that exists is refused plainly")
    func refusals() async throws {
        let s = try await Self.setup()
        defer { try? FileManager.default.removeItem(at: s.root) }
        await #expect(throws: ToolInputError.self) { _ = try await s.tool.run(arguments: ["branch": "nope"]) { _ in } }
        await #expect(throws: ToolInputError.self) { _ = try await s.tool.run(arguments: ["branch": "bad name"]) { _ in } }
        await #expect(throws: ToolInputError.self) { _ = try await s.tool.run(arguments: ["branch": "feature", "create": true]) { _ in } }
        #expect(s.changes.base.branch == "main")
        #expect(SwitchBranchTool.clean("origin/feature") == "feature")
        #expect(SwitchBranchTool.clean("refs/heads/a/b") == "a/b")
        #expect(SwitchBranchTool.clean("-x") == nil && SwitchBranchTool.clean("a..b") == nil && SwitchBranchTool.clean("a~1") == nil)
    }

    @Test("An open pull request is continued only from its own branch")
    func pullRequestOnlyContinuesOnItsBranch() async throws {
        let s = try await Self.setup()
        defer { try? FileManager.default.removeItem(at: s.root) }
        // A save on main opens a pull request from a side branch, as before.
        try await s.changes.edit(path: "MAIN.md", text: "changed\n")
        _ = try await s.save.runApproved(arguments: ["title": "Main change"]) { _ in }
        #expect(s.changes.base.branch.hasPrefix("maipa-g/main-change-"))
        // Moved to feature, the next save goes to feature, not to that pull request's branch.
        _ = try await s.tool.run(arguments: ["branch": "feature"]) { _ in }
        try await s.changes.edit(path: "README.md", text: "on feature\n")
        _ = try await s.save.runApproved(arguments: ["title": "Feature change"]) { _ in }
        let commit = try #require(s.github.branchHeads["feature"])
        #expect(s.github.commits[commit]?.parent == s.featureHead)
    }

    @Test("The computer's copy follows the switch before the next command", .enabled(if: onLinux))
    func mirrorFollowsTheBranch() async throws {
        let s = try await Self.setup()
        defer { try? FileManager.default.removeItem(at: s.root) }
        let mirror = ComputerRepoMirror(control: ComputerControl.local(machine: "test", home: s.root), workspace: s.changes, homePath: "repos/octo/demo", commit: s.mainHead, gate: { _, _ in true })
        _ = try await s.tool.run(arguments: ["branch": "feature"]) { _ in }
        await mirror.followBase()
        #expect(await mirror.startCommit == s.featureHead)
        #expect(await !mirror.isStarted)
        #expect(ComputerMirroredTool.role(for: SwitchBranchTool.toolName) == .switchBranch)
    }
}
