import Foundation
import Testing
@testable import AgentCore

@Suite("29 October completion regressions")
struct CompletionRegressionTests {
    @Test func OCT29_09_createRepositoryAlwaysRequiresApproval() async throws {
        let github = FakeGitHub().client
        let tool = CreateRepositoryTool(github: github)
        let arguments: JSONValue = ["name": "new-private", "private": true]
        #expect(await tool.approvalRequest(for: arguments)?.question.contains("new-private") == true)
        await #expect(throws: ToolApprovalRequired.self) {
            _ = try await tool.run(arguments: arguments, progress: { _ in })
        }
    }

    @Test func OCT29_12_liveStatusNeverReturnsTokens() async throws {
        let secret = "ghs_abcdefghijklmnopqrstuvwxyz123456"
        let tool = LiveStatusTool { "Job running with Bearer \(secret)" }
        let output = try await tool.run(arguments: [:], progress: { _ in })
        #expect(!output.forModel.contains(secret))
        #expect(output.forModel.contains(SensitiveDataRedactor.marker))
    }

    @Test func OCT29_18_otherRepoNamesOfferExactCloseMatches() async {
        let repos = [
            GitHubRepo(id: 1, name: "Continuum-", fullName: "octo/Continuum-", ownerLogin: "octo", isPrivate: true, defaultBranch: "master", htmlURL: "https://github.com/octo/Continuum-"),
            GitHubRepo(id: 2, name: "MAIPA-G", fullName: "octo/MAIPA-G", ownerLogin: "octo", isPrivate: false, defaultBranch: "main", htmlURL: "https://github.com/octo/MAIPA-G"),
        ]
        let tool = ReadOtherRepositoryFileTool(github: FakeGitHub().client, repositories: repos)
        do {
            _ = try await tool.run(arguments: ["repository": "Continuum", "path": "README.md"], progress: { _ in })
            Issue.record("Expected a close-match correction")
        } catch {
            #expect(String(describing: error).contains("octo/Continuum-"))
        }
    }

    @Test func OCT29_17_http500IsRetriable() {
        let error = HTTPError.status(code: 500, body: "Internal Server Error", headers: [:])
        #expect(defaultRetryDelay(error) != nil)
    }
}
