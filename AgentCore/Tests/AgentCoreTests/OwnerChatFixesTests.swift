import Foundation
import Testing
@testable import AgentCore

/// The owner's screenshots of 15 and 16 November 2026: his Signer chat (snes-tas-studio) couldn't
/// save to main and lost work to git on the computer, its IPA "didn't come through", his Korg chat
/// showed two screenshots from another chat, and an empty TeamoRouter wallet read as a broken request.
@Suite("Saving, files and pictures on the computer, and provider balances")
struct OwnerChatFixesTests {
    #if os(Linux)
    static let onLinux = true
    #else
    static let onLinux = false
    #endif

    static func workspace(_ github: FakeGitHub, root: URL) throws -> ChangeWorkspace {
        let base = RepoWorkspace(repo: RepoRef(owner: "octo", name: "MAIPA-G-data"), branch: "main", commit: try #require(github.head), github: github.client, store: SnapshotStore(root: root))
        return ChangeWorkspace(base: base)
    }

    @Test("Deleting a file made in this chat stages nothing, and a leftover deletion can't stop a save")
    func deletingANewFileDoesNotBreakSaving() async throws {
        let github = FakeGitHub()
        github.commitRemotely(["README.md": Data("old\n".utf8)])
        github.rejectsDeletingMissingPaths = true
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("maipag-delete-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let changes = try Self.workspace(github, root: root)

        // What the Signer reply did: a probe file, then delete_file on it.
        try await changes.create(path: "Tests/TempP12Probe.swift", text: "probe\n")
        let tool = DeleteFileTool(workspace: changes, authorization: ChangeAuthorization(deletion: true, buildSetup: false))
        let output = try await tool.runApproved(arguments: ["path": "Tests/TempP12Probe.swift"], progress: { _ in })
        #expect(output.forModel.contains("never saved"))
        #expect(await changes.stagedChanges().isEmpty)

        // A deletion like that left from before (restored with the chat) is dropped at save time.
        await changes.restoreStaged([
            .delete(path: "Tests/Ghost.swift", previous: Data("probe\n".utf8)),
            .write(path: "README.md", data: Data("new\n".utf8), existed: true),
        ])
        let receipt = try await GitHubChangeService(github: github.client).save(changes, selectedBranch: "main", defaultBranch: "main", rules: RepoWriteRules(directSave: true), title: "Fix the password dead end")
        #expect(receipt.branch == "main")
        #expect(github.remoteFile("README.md") == Data("new\n".utf8))
    }

    @Test("TeamoRouter's empty wallet is an empty balance, with TeamoRouter's own top-up page")
    func teamoRouterEmptyWallet() throws {
        let body = Data(#"{"error":{"code":"enterprise_insufficient_balance","message":"Your TeamoRouter wallet balance is insufficient. Recharge at https://teamorouter.com/dashboard?buy=1 to continue.","type":"insufficient_balance"}}"#.utf8)
        let error = OpenRouterAPIError(status: 400, body: body, headers: [:], providerName: "TeamoRouter")
        #expect(error.kind == .outOfCredits)
        #expect(error.topUpURL?.absoluteString == "https://teamorouter.com/dashboard?buy=1")
        let failure = AgentLoop.describe(error)
        #expect(failure.kind == .outOfCredits)
        #expect(failure.actionURL == "https://teamorouter.com/dashboard?buy=1")
        #expect(failure.message.contains("TeamoRouter balance has run out"))
        #expect(failure.message.contains("\"-free\" models need money in the wallet too"))
        #expect(failure.message.contains("Use a free AI"))
        // A 400 that isn't about money is still a bad request.
        let other = OpenRouterAPIError(status: 400, body: Data(#"{"error":{"message":"Unsupported parameter: reasoning"}}"#.utf8), headers: [:], providerName: "TeamoRouter")
        #expect(other.kind == .badRequest)
        // OpenRouter's own empty balance keeps OpenRouter's buttons.
        let openRouter = AgentLoop.describe(OpenRouterAPIError(status: 402, body: Data(#"{"error":{"code":402,"message":"Insufficient credits"}}"#.utf8), headers: [:]))
        #expect(openRouter.kind == .outOfCredits && openRouter.actionURL == nil)
    }

    /// TeamoRouter's own price list for its two GLM 5.3 Flash models, as it answered on 16 November 2026.
    final class TeamoPrices: HTTPTransport, @unchecked Sendable {
        func send(_ request: HTTPRequest) async throws -> HTTPResponse {
            switch request.url.path {
            case "/v1/models":
                return HTTPResponse(status: 200, body: Data(#"{"data":[{"id":"glm-5.3-flash-free"},{"id":"glm-5.3-flash"}]}"#.utf8))
            case "/v1/models/pricing":
                return HTTPResponse(status: 200, body: Data(#"""
                {"models":[
                 {"id":"glm-5.3-flash-free","display_name":"GLM 5.3 Flash福利版","base_model_id":"glm-5.3-flash","context_window":1000000,"cost":{"input":0.000114,"output":0.0004,"cached_input":3e-05,"cache_read":3e-05},"list_cost":{"currency":"USD","input":0.114,"output":0.4,"cached_input":0.03,"cache_read":0.03},"discount_rate":0.001},
                 {"id":"glm-5.3-flash","display_name":"GLM-5.3-Flash (Ox Alpha)","context_window":1000000,"cost":{"input":0.057,"output":0.2,"cache_read":0.015},"list_cost":{"currency":"USD","input":0.114,"output":0.4,"cache_read":0.03},"discount_rate":0.5}
                ]}
                """#.utf8))
            default:
                return HTTPResponse(status: 404)
            }
        }
        func stream(_ request: HTTPRequest) async throws -> HTTPStreamResponse {
            HTTPStreamResponse(status: 404, headers: [:], body: AsyncThrowingStream { $0.finish() })
        }
    }

    @Test("TeamoRouter's \"-free\" GLM isn't shown as free: it has a price and needs a balance")
    func teamoRouterLowLaneIsNotFree() async throws {
        let endpoint = AIProviderEndpoint(id: "teamorouter", name: "TeamoRouter", baseURL: "https://api.teamorouter.com/v1", apiKey: "sk-teamo-test", isEnabled: true)
        let models = try await AIProviderGateway.fetchModels(for: endpoint, transport: TeamoPrices()).models
        let glm = try #require(models.first { AIProviderModelID.rawModelID($0.id) == "glm-5.3-flash-free" })
        #expect(!glm.isFree)
        #expect(((glm.promptPrice ?? 0) * 1_000_000 * 1_000_000).rounded() == 114)
        #expect(glm.percentOffList == 99)
        #expect(glm.summary?.contains("needs money in the wallet") == true)
        let route = ModelRouter.route(choice: .model(glm.id), difficulty: .normal, thinking: .medium, account: AccountState(), catalogue: [glm.id: glm])
        #expect(!route.isFree)
        // OpenRouter's ":free" models are still free.
        #expect(ModelInfo(id: "nvidia/nemotron-3.5-lightning:free", name: "Nemotron", promptPrice: 0, completionPrice: 0).isFree)
    }

    @Test("A reply carried on with another AI says that AI, not the one it stopped on")
    func carriedOnReplyNamesTheNewAI() async throws {
        var step = AssistantStep()
        step.text = "Saving these fixes to PR #1."
        step.finishedAt = Date()
        var stopped = AssistantTurn(status: .failed, steps: [step], notices: [AgentLoop.stoppedEarlyNotice])
        stopped.stoppedEarly = true
        stopped.routeLabel = "GPT 6.1 Sol"
        var chat = Chat()
        chat.messages = [.user("Fix it"), ChatMessage(body: .assistant(stopped))]
        let transport = ScriptedTransport([.events([AgentLoopTests.text("Done."), AgentLoopTests.done])])
        let environment = AgentEnvironment(openRouter: OpenRouterClient(transport: transport, apiKey: "sk-test"), freeRoute: { AgentLoopTests.route() }, onOutOfCredits: {})
        var route = AgentLoopTests.route()
        route.label = "GLM 5.3 Flash"
        var last: AssistantTurn?
        for await event in AgentLoop.run(AgentTurnInput(chat: chat, route: route, systemPrompt: "system", tools: [], resumeNote: AgentLoop.resumeNote(partialText: step.text)), environment: environment) {
            if case .updated(let turn, _) = event { last = turn }
        }
        #expect(last?.routeLabel == "GLM 5.3 Flash")
    }

    @Test("A Tap-retry note isn't shown under a reply that carried on and finished")
    func staleRetryNoteHidden() {
        let old = "The reply ended on your computer without finishing (the runner stopped). Tap retry to carry on from where it stopped."
        var turn = AssistantTurn()
        turn.notices = [old, "This reply hit its length limit and may be cut off."]
        turn.status = .stopped
        #expect(turn.shownNotices.contains(old))
        turn.status = .done
        #expect(!turn.shownNotices.contains(old))
        #expect(turn.shownNotices.contains("This reply hit its length limit and may be cut off."))
    }

    @Test("A file with spaces in its name comes back from the computer", .enabled(if: onLinux))
    func spacesInNames() async throws {
        let home = try ComputerRunnerTests.temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let folder = home.appendingPathComponent(".maipa-g/runs/turn-1/data/media/abc", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let bytes = Data((0..<70_000).map { UInt8($0 % 251) })
        try bytes.write(to: folder.appendingPathComponent("Signer build 38 (it's $HOME).ipa"))
        let control = ComputerControl.local(machine: "test", home: home)
        let read = try await control.readFile(homePath: ".maipa-g/runs/turn-1/data/media/abc/Signer build 38 (it's $HOME).ipa")
        #expect(read == bytes)
        #expect(!ComputerControl.isSafeHomePath("../outside.ipa"))
        #expect(!ComputerControl.isSafeHomePath("/etc/passwd"))
        #expect(!ComputerControl.isSafeHomePath("a\nb"))
    }

    @Test("The AI can look at a picture without putting it in the chat; another chat's files are refused", .enabled(if: onLinux))
    func picturesStayInTheirChat() async throws {
        let home = try ComputerRunnerTests.temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let control = ComputerControl.local(machine: "test", home: home)
        // A 1x1 PNG.
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==")!
        let mine = AttachmentReference(name: "Photo.jpg", mimeType: "image/jpeg", kind: .image, path: "attachments/x/Photo.jpg", bytes: png.count)
        let other = AttachmentReference(name: "Photo.jpg", mimeType: "image/jpeg", kind: .image, path: "attachments/y/Photo.jpg", bytes: png.count)
        for reference in [mine, other] {
            let url = home.appendingPathComponent(ComputerControl.attachmentHomePath(reference))
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try png.write(to: url)
        }
        try FileManager.default.createDirectory(at: home.appendingPathComponent("pictures"), withIntermediateDirectories: true)
        try png.write(to: home.appendingPathComponent("pictures/frame one.png"))

        let view = ViewComputerPictureTool(control: control, chatFiles: [mine])
        let looked = try await view.run(arguments: ["path": "~/pictures/frame one.png"], progress: { _ in })
        #expect(looked.inlineImages.count == 1)
        #expect(looked.generatedImages.isEmpty)
        let own = try await view.run(arguments: ["path": .string("/home/sprite/" + ComputerControl.attachmentHomePath(mine))], progress: { _ in })
        #expect(own.inlineImages.count == 1)
        await #expect(throws: ToolInputError.self) {
            _ = try await view.run(arguments: ["path": .string(ComputerControl.attachmentHomePath(other))], progress: { _ in })
        }
        let store = AttachmentStore(dataDirectory: home.appendingPathComponent("store", isDirectory: true))
        let show = ShowComputerPictureTool(control: control, store: store, chatFiles: [mine])
        await #expect(throws: ToolInputError.self) {
            _ = try await show.run(arguments: ["path": .string("~/" + ComputerControl.attachmentHomePath(other))], progress: { _ in })
        }
    }

    @Test("The computer's git is on the chat's branch, and follows a save without touching the files", .enabled(if: onLinux))
    func gitOnTheComputerTellsTheTruth() async throws {
        let home = try ComputerRunnerTests.temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try await ComputerRunnerTests.shell("""
        set -e
        mkdir -p repos/o/r && cd repos/o/r
        git init -q && git -c user.name=t -c user.email=t@x commit -q --allow-empty -m start
        printf 'one\\n' > README.md && git add README.md && git -c user.name=t -c user.email=t@x commit -q -m readme
        """, in: home)
        let first = try await ComputerRunnerTests.shell("cd repos/o/r && git rev-parse HEAD", in: home).trimmingCharacters(in: .whitespacesAndNewlines)
        let control = ComputerControl.local(machine: "test", home: home)
        _ = try await control.syncStagedChanges(homePath: "repos/o/r", cloneURL: nil, commit: first, changes: [.write(path: "README.md", data: Data("two\n".utf8), existed: true)], branch: "main")
        let state = try await ComputerRunnerTests.shell("cd repos/o/r && git branch --show-current && git rev-parse origin/main && cat README.md", in: home)
        #expect(state.split(separator: "\n").map(String.init) == ["main", first, "two"], "\(state)")

        // GitHub made the saved commit; here it's made the same way, without moving anything.
        let saved = try await ComputerRunnerTests.shell("""
        cd repos/o/r && idx=$(mktemp) && GIT_INDEX_FILE=$idx git read-tree HEAD && GIT_INDEX_FILE=$idx git update-index --add README.md && t=$(GIT_INDEX_FILE=$idx git write-tree) && git -c user.name=t -c user.email=t@x commit-tree "$t" -p HEAD -m saved
        """, in: home).trimmingCharacters(in: .whitespacesAndNewlines)
        let followed = try await control.run(ComputerRepoMirror.followSaveScript(homePath: "repos/o/r", commit: saved, branch: "maipa-g/fix-the-password-1a2b3c4d"))
        #expect(followed.contains("maipa-g-followed") && followed.contains("maipa-g-on-branch"), "\(followed)")
        let after = try await ComputerRunnerTests.shell("cd repos/o/r && git branch --show-current && git rev-parse HEAD origin/maipa-g/fix-the-password-1a2b3c4d && git status --porcelain | wc -l && cat README.md", in: home)
        #expect(after.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) } == ["maipa-g/fix-the-password-1a2b3c4d", saved, saved, "0", "two"], "\(after)")
        #expect(!ComputerControl.isPlainBranchName("main; rm -rf ~"))
        #expect(!ComputerControl.isPlainBranchName("-x"))
    }
}
