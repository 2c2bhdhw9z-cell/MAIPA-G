import Foundation
import Testing
@testable import AgentCore

/// Owner, 11 November 2026: "if I told you only ever push to main, then you would just do that
/// and you wouldn't tell me 'oh I can't do that'. And if I tell you everything should be a PR or
/// branch, then you would do that." What the person says decides how changes are saved.
@Suite("Saving the way the person says")
struct SavingStyleTests {
    static let repo = RepoRef(owner: "me", name: "app")

    static func tool(rules: RepoWriteRules, choice: SavingStyleChoice?) -> SaveChangesTool {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("maipa-g-style-\(UUID().uuidString)")
        let github = GitHubClient(transport: URLSessionTransport(), tokens: nil)
        let base = RepoWorkspace(repo: repo, branch: "main", commit: String(repeating: "a", count: 40), github: github, store: SnapshotStore(root: directory))
        return SaveChangesTool(
            workspace: ChangeWorkspace(base: base), service: GitHubChangeService(github: github), session: ChangeSession(receipts: []),
            selectedBranch: "main", defaultBranch: "main", rules: rules, choice: choice
        )
    }

    @Test("Telling the AI how to save is understood in either direction, for every repo unless one is named")
    func parsesTheChoice() {
        #expect(SetSavingStyleTool.parse(["style": "straight_to_branch"])! == (true, true))
        #expect(SetSavingStyleTool.parse(["style": "pull_request", "scope": "this_repo"])! == (false, false))
        #expect(SetSavingStyleTool.parse(["style": "sideways"]) == nil)
    }

    @Test("What the person said wins over the repo's rules, and a direct save they asked for doesn't ask again")
    func theirWordWins() async throws {
        let choice = SavingStyleChoice()
        let saving = Self.tool(rules: RepoWriteRules(directSave: false), choice: choice)
        #expect(await saving.effectiveRules().directSave == false)
        let set = SetSavingStyleTool(choice: choice, repoName: Self.repo.fullName)
        let output = try await set.run(arguments: ["style": "straight_to_branch"]) { _ in }
        #expect(output.forModel.contains("every repo"))
        #expect(await saving.effectiveRules().directSave == true)
        #expect(await saving.approvalRequest(for: ["title": "x"]) == nil)
        _ = try await set.run(arguments: ["style": "pull_request"]) { _ in }
        #expect(await saving.effectiveRules().directSave == false)
    }

    @Test("Only a repo's rules file on its own still asks before saving straight to main")
    func aRulesFileAloneAsks() async {
        let fromFile = RepoWriteRules.resolve(documents: [(path: "AGENTS.md", text: "No pull requests.")], directSaveSetting: false)
        #expect(fromFile.directSave && !fromFile.directSaveFromPerson)
        #expect(await Self.tool(rules: fromFile, choice: nil).approvalRequest(for: ["title": "x"]) != nil)
        let fromSetting = RepoWriteRules.resolve(documents: [], directSaveSetting: true)
        #expect(await Self.tool(rules: fromSetting, choice: nil).approvalRequest(for: ["title": "x"]) == nil)
        let fromMessage = RepoWriteRules.resolve(documents: [], directSaveSetting: false, requestText: "only push to main")
        #expect(fromMessage.directSaveFromPerson)
        #expect(await Self.tool(rules: fromMessage, choice: nil).approvalRequest(for: ["title": "x"]) == nil)
    }
}
