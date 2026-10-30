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

    // Report 8: an app-restricted AI is recognised from OpenRouter's 403, explained in plain
    // words, and handed to the app to hide from the picker.
    @Test func OCT29_08_appRestrictedModelsAreRecognisedAndHidden() throws {
        let body = Data(#"{"error":{"code":403,"message":"This model is only available on agentic harnesses listed on openrouter.ai/apps"}}"#.utf8)
        let restricted = OpenRouterAPIError(status: 403, body: body, headers: [:])
        #expect(restricted.kind == .appRestricted)
        let failure = AgentLoop.describe(restricted)
        #expect(failure.message.contains("hidden from the AI picker"))
        let moderated = OpenRouterAPIError(status: 403, body: Data(#"{"error":{"code":403,"message":"Input was flagged by moderation"}}"#.utf8), headers: [:])
        #expect(moderated.kind == .moderated)
        // Music and image-only models never reach the chat picker.
        let catalogue = Data(#"{"data":[{"id":"google/lyria-3-pro-preview","name":"Lyria 3 Pro Preview","architecture":{"input_modalities":["text"],"output_modalities":["audio"]},"pricing":{"prompt":"0","completion":"0"}},{"id":"x/chat","name":"Chat","architecture":{"input_modalities":["text"],"output_modalities":["text"]},"pricing":{"prompt":"0","completion":"0"}}]}"#.utf8)
        let models = try ModelInfo.parseCatalogue(catalogue)
        #expect(models.filter(\.isChatModel).map(\.id) == ["x/chat"])
    }

    // Report 14: a web project inside a folder (a Vite app in web/ beside native/) is found and
    // built in that folder.
    @Test func OCT29_14_webProjectsInsideFoldersAreFoundAndBuiltThere() throws {
        let paths = ["README.md", "native/Cargo.toml", "native/src/main.rs", "web/package.json", "web/vite.config.ts", "web/index.html", "web/src/main.ts"]
        let project = try #require(WebProjectDetector.detect(paths: paths, packageJSON: Data(#"{"scripts":{"build":"vite build"}}"#.utf8)))
        #expect(project.kind == .buildArtifact && project.rootPath == "web" && project.buildCommand == "npm run build")
        #expect(WebProjectDetector.packageFolder(paths: ["tools/package.json", "site/package.json"]) == "site")
        #expect(WebProjectDetector.packageFolder(paths: ["b/package.json", "a/package.json", "b/vite.config.js"]) == "b")
        #expect(WebProjectDetector.packageFolder(paths: ["node_modules/package.json", ".cache/package.json"]) == nil)
        // A root site still wins, and nothing outside the repo is accepted.
        #expect(WebProjectDetector.detect(paths: ["index.html", "web/package.json"])?.rootPath == "")
        #expect(WebProjectDetector.detect(paths: ["../web/package.json"]) == nil)

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(CloudRunner.previewInstallCommand(in: folder) == "npm install")
        try Data().write(to: folder.appendingPathComponent("pnpm-lock.yaml"))
        #expect(CloudRunner.previewInstallCommand(in: folder) == "pnpm install --frozen-lockfile")
    }
}
