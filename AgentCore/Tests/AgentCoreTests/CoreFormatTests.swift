import Clibsodium
import Foundation
import Testing
@testable import AgentCore

@Suite("JSON and hashing")
struct CoreFormatTests {
    @Test func jsonRoundTripKeepsIntegersWhole() throws {
        let value: JSONValue = ["id": 12, "price": 0.5, "name": "x", "ok": true, "none": nil, "list": [1, "two"]]
        let text = value.jsonString()
        #expect(text == #"{"id":12,"list":[1,"two"],"name":"x","none":null,"ok":true,"price":0.5}"#)
        #expect(JSONValue.parse(text) == value)
    }

    @Test func numbersAreNotMistakenForBooleans() {
        #expect(JSONValue.parse("1") == .number(1))
        #expect(JSONValue.parse("true") == .bool(true))
        #expect(JSONValue.parse(#"{"a":0}"#)?["a"]?.intValue == 0)
    }

    @Test func datesRoundTripWithMilliseconds() throws {
        struct Box: Codable, Equatable { var date: Date }
        let box = Box(date: Date(timeIntervalSince1970: 1_761_700_000.123))
        let data = try JSONCoding.encoder().encode(box)
        let decoded = try JSONCoding.decoder().decode(Box.self, from: data)
        #expect(abs(decoded.date.timeIntervalSince1970 - box.date.timeIntervalSince1970) < 0.001)
        // GitHub's whole-second dates read too.
        let github = try JSONCoding.decoder().decode(Box.self, from: Data(#"{"date":"2026-10-28T03:55:00Z"}"#.utf8))
        #expect(github.date.timeIntervalSince1970 == 1_793_159_700)
    }

    @Test func gitBlobIDMatchesGit() {
        // `printf 'hello\n' | git hash-object --stdin`
        #expect(Hashing.gitBlobID(Data("hello\n".utf8)) == "ce013625030ba8dba906f756967f9e9ca394464a")
        // The empty file.
        #expect(Hashing.gitBlobID(Data()) == "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391")
    }

    @Test func pkceMatchesTheRFCExample() {
        // Checked with Python: base64url(sha256(verifier)) without padding.
        let pkce = PKCE(verifier: "dBjftJeZ4CVP-mJ92K9rIn2ky-qD9-kOaeH-SiUpY4U")
        #expect(pkce.challenge == "kCqRomV8XVt03HEMnNlTFGGgqKZAmQrX40se9cONvl8")
        #expect(PKCE().verifier.count == 43)
    }

    @Test func base64URLRoundTrips() {
        let data = Data([0xfb, 0xff, 0xfe, 0x00, 0x10])
        let encoded = Base64URL.encode(data)
        #expect(!encoded.contains("+") && !encoded.contains("/") && !encoded.contains("="))
        #expect(Base64URL.decode(encoded) == data)
    }

    @Test func buildTwoRecordsAndOldMessagesRoundTrip() throws {
        let old = try JSONCoding.decoder().decode(UserMessage.self, from: Data(#"{"text":"hello"}"#.utf8))
        #expect(old.text == "hello" && old.attachments.isEmpty)

        let attachment = AttachmentReference(name: "photo.jpg", mimeType: "image/jpeg", kind: .image, path: "attachments/id/photo.jpg", bytes: 12)
        let message = UserMessage(text: "look", attachments: [attachment])
        let decodedMessage = try JSONCoding.decoder().decode(UserMessage.self, from: JSONCoding.encoder().encode(message))
        #expect(decodedMessage.text == message.text)
        #expect(decodedMessage.attachments.map(\.id) == message.attachments.map(\.id))

        let memory = MemoryRecord(text: "Use plain words", source: .star)
        let decodedMemory = try JSONCoding.decoder().decode(MemoryRecord.self, from: JSONCoding.encoder().encode(memory))
        #expect(decodedMemory.id == memory.id && decodedMemory.text == memory.text && decodedMemory.source == .star)
        #expect(Chat.currentFormat == 3)
    }

    @Test func oldChatDefaultsGroupsStarsAndMemories() throws {
        var chat = Chat(title: "Old")
        chat.messages = [.user("hello")]
        var object = try #require(JSONSerialization.jsonObject(with: JSONCoding.encoder().encode(chat)) as? [String: Any])
        object.removeValue(forKey: "groupID")
        object.removeValue(forKey: "memoryContext")
        object.removeValue(forKey: "saveReceipts")
        if var messages = object["messages"] as? [[String: Any]], !messages.isEmpty {
            messages[0].removeValue(forKey: "starredMemoryID")
            object["messages"] = messages
        }
        let decoded = try JSONCoding.decoder().decode(Chat.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.groupID == nil)
        #expect(decoded.memoryContext.isEmpty)
        #expect(decoded.messages.first?.starredMemoryID == nil)
    }

    @Test func specsApproveInOrderAndResumeTasks() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("maipag-specs-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = SpecCoordinator(dataDirectory: root)
        let repo = RepoRef(owner: "octo", name: "app")
        var spec = try await coordinator.create(title: "Login Screen", request: "Build login", repo: repo, branch: "main", defaultBranch: "main")
        #expect(spec.slug == "login-screen")
        let second = try await coordinator.create(title: "Login Screen", request: "Another", repo: repo, branch: "main", defaultBranch: "main")
        #expect(second.slug == "login-screen-2")
        await #expect(throws: SpecFailure.self) { try await coordinator.approve(spec.id, stage: .design) }

        for (stage, text) in [
            (SpecStage.requirements, "# Requirements"),
            (.design, "# Design"),
            (.checkedDesign, "# Checked design"),
            (.tasks, "- [ ] First task\n- [ ] Second task"),
        ] {
            spec = try await coordinator.updateArtifact(spec.id, stage: stage, text: text)
            spec = try await coordinator.approve(spec.id, stage: stage)
        }
        #expect(spec.stage == .execution && spec.tasks.count == 2)
        spec = try await coordinator.completeTask(spec.id, taskID: spec.tasks[0].id)
        let restored = try #require(await coordinator.load(spec.id))
        #expect(restored.tasks[0].isComplete && restored.stage == .execution)
        spec = try await coordinator.completeTask(spec.id, taskID: spec.tasks[1].id)
        #expect(spec.stage == .completed)
        #expect(spec.path(for: .requirements) == ".kiro/specs/login-screen/requirements.md")
        #expect(SpecWorkflows.draft(.checkedDesign, context: "x").steps.first?.agentID == "design-checker")
        let execution = SpecWorkflows.execute(task: SpecTask(title: "Implement login"), context: "approved")
        #expect(execution.steps.first?.kind == .repeatUntil)
        #expect(execution.steps.first?.maximumIterations == 3)
        #expect(execution.steps.first?.children.map(\.agentID) == ["coder", "code-checker"])
        #expect(execution.steps.first?.children.last?.instruction?.contains("Do not edit") == true)
    }

    @Test func memoryAndGroupRecordsRoundTripWithSourcesAndDates() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("maipag-product-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let messageID = UUID()
        let memoryStore = ProductStore<MemoryRecord>(dataDirectory: root, folder: "memories")
        let groupStore = ProductStore<ChatGroupRecord>(dataDirectory: root, folder: "groups")
        let memory = MemoryRecord(text: "Use plain words", isEnabled: false, source: .star, sourceMessageID: messageID, createdAt: Date(timeIntervalSince1970: 100))
        let group = ChatGroupRecord(name: "Project", order: 2)
        try await memoryStore.save(memory)
        try await groupStore.save(group)
        let loaded = try #require(await memoryStore.load(memory.id))
        #expect(loaded.source == .star && loaded.sourceMessageID == messageID && !loaded.isEnabled)
        #expect(loaded.createdAt == Date(timeIntervalSince1970: 100))
        #expect(await groupStore.load(group.id)?.order == 2)

        let starMessage = UUID()
        let firstStar = try await StarMemoryService.toggle(store: memoryStore, messageID: starMessage, text: "A starred message", currentMemoryID: nil)
        let countAfterFirst = await memoryStore.loadAll().count
        let secondStar = try await StarMemoryService.toggle(store: memoryStore, messageID: starMessage, text: "A starred message", currentMemoryID: firstStar)
        #expect(countAfterFirst == 2)
        #expect(secondStar == nil)
        if let firstStar { #expect(await memoryStore.load(firstStar) == nil) }

        let chatStore = ChatStore(dataDirectory: root)
        var grouped = Chat(title: "Keep me", groupID: group.id)
        grouped.messages = [.user("Still here")]
        try await chatStore.save(grouped)
        #expect(try await chatStore.clearGroup(group.id) == 1)
        let kept = try #require(await chatStore.load(grouped.id))
        #expect(kept.groupID == nil && kept.messages.first?.userText == "Still here")
    }

    @Test func builtInAgentsAndWorkflowsHaveCompletePolicies() throws {
        #expect(BuiltInAgents.all.map(\.name) == [
            "Planner", "Designer", "Design checker", "Coder", "Code checker", "Second opinion",
            "Review combiner", "Investigator", "Researcher", "Builder", "Workflow maker",
            "Request sender", "Feedback answerer",
        ])
        #expect(Set(BuiltInAgents.all.map(\.id)).count == 13)
        #expect(BuiltInAgents.named("investigator")?.permits(tool: "edit_file") == false)
        #expect(BuiltInAgents.named("code-checker")?.modelPolicy == .strong)
        #expect(BuiltInAgents.named("second-opinion")?.modelPolicy == .differentFromPrimary)
        #expect(BuiltInAgents.named("coder")?.permits(tool: "run_shell") == true)
        #expect(BuiltInAgents.named("researcher")?.permits(tool: "run_shell") == true)
        #expect(BuiltInAgents.named("investigator")?.permits(tool: "run_shell") == false)
        #expect(BuiltInAgents.named("builder")?.behavior == .build)
        #expect(BuiltInAgents.named("request-sender")?.behavior == .pullRequest)
        #expect(BuiltInAgents.named("feedback-answerer")?.behavior == .feedback)
        #expect(CloudToolAssembly.availableToolNames(for: try #require(BuiltInAgents.named("coder"))).contains("run_shell"))
        #expect(CloudToolAssembly.availableToolNames(for: try #require(BuiltInAgents.named("researcher"))).contains("run_shell"))
        #expect(CloudToolAssembly.availableToolNames(for: try #require(BuiltInAgents.named("builder"))).isSuperset(of: ["dispatch_workflow", "read_checks", "read_workflow_logs", "list_artifacts", "inspect_ipa"]))
        #expect(CloudToolAssembly.availableToolNames(for: try #require(BuiltInAgents.named("request-sender"))).contains("create_pull_request"))
        #expect(CloudToolAssembly.availableToolNames(for: try #require(BuiltInAgents.named("feedback-answerer"))).isSuperset(of: ["run_shell", "read_pull_request_comments", "reply_to_review_comment"]))
        #expect(!CloudToolAssembly.availableToolNames(for: try #require(BuiltInAgents.named("code-checker"))).contains("run_shell"))

        #expect(BuiltInWorkflows.all.map(\.name) == [
            "Look into something", "Keep going until a goal is met", "Work through a checklist",
            "Full feature", "Two-AI review", "Experiment until it's better",
            "Send a side copy for review", "Build and check the IPA",
        ])
        let agentIDs = Set(BuiltInAgents.all.map(\.id))
        #expect(BuiltInWorkflows.all.allSatisfy { $0.isApproved && $0.validationErrors(agentIDs: agentIDs).isEmpty })
        let full = try #require(BuiltInWorkflows.named("full-feature"))
        #expect(full.steps.map(\.title) == ["Requirements", "Approve requirements", "Design", "Approve design", "Checked design", "Approve checked design", "Implementation plan", "Approve implementation plan", "Implementation", "Independent two-AI review", "Combine reviews", "Final check"])
        #expect(full.steps[9].children.map(\.agentID) == ["code-checker", "second-opinion"])
    }

    @Test func customAutomationRecordsRoundTripWithoutPersistingBuiltIns() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("maipag-automation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let agents = ProductStore<CustomAgentRecord>(dataDirectory: root, folder: "agents")
        let workflows = ProductStore<WorkflowRecord>(dataDirectory: root, folder: "workflows")
        let custom = CustomAgentRecord(name: "Release reader", summary: "Checks releases", instructions: "Inspect releases and report.", allowedTools: ["read_releases"], difficulty: .hard, behavior: .reportOnly, maximumHelpers: 2)
        try await agents.save(custom)
        let generated = WorkflowDefinition(id: "generated", name: "Release flow", summary: "Build, ask, and review", steps: [
            .repeatUntil("repeat", title: "Repair", maximum: 4, goal: "Checks pass", steps: [
                .agent("build", title: "Build", agent: "coder", instruction: "Implement and check."),
                .agent("check", title: "Check", agent: custom.definition.id, instruction: "Check the release."),
            ]),
            .ask("approval", title: "Approval", question: "Send it?", options: ["Send", "Stop"]),
            .parallel("reviews", title: "Reviews", agents: [
                .agent("primary", title: "Primary", agent: "code-checker", instruction: "Review."),
                .agent("second", title: "Second", agent: "second-opinion", instruction: "Review independently."),
            ]),
        ], isApproved: false)
        let response = "```json\n" + String(decoding: try JSONCoding.encoder().encode(generated), as: UTF8.self) + "\n```"
        let draft = try WorkflowDraftBuilder.generatedDraft(from: response, agentIDs: Set(BuiltInAgents.all.map(\.id)).union([custom.definition.id]))
        let record = WorkflowRecord(definition: draft)
        try await workflows.save(record)
        let loadedAgent = try #require(await agents.load(custom.id))
        let loadedWorkflow = try #require(await workflows.load(record.id))
        #expect(loadedAgent.definition.name == "Release reader")
        #expect(loadedAgent.definition.maximumHelpers == 2)
        #expect(!loadedWorkflow.definition.isApproved)
        #expect(loadedWorkflow.steps.contains { $0.kind == .parallel })
        #expect(await agents.loadAll().count == 1)
        #expect(await workflows.loadAll().count == 1)
        #expect(!BuiltInAgents.all.contains { $0.id == loadedAgent.definition.id })
    }

    @Test func oldCustomAgentDefaultsNewPolicyFields() throws {
        let id = UUID()
        let data = Data("""
        {"format":1,"id":"\(id.uuidString)","name":"Old","instructions":"Report","allowedTools":["read_file"],"createdAt":"2026-10-28T00:00:00Z","updatedAt":"2026-10-28T00:00:00Z"}
        """.utf8)
        let record = try JSONCoding.decoder().decode(CustomAgentRecord.self, from: data)
        #expect(record.behavior == .changesAllowed)
        #expect(record.difficulty == .normal)
        #expect(record.maximumHelpers == 0)
    }

    @Test func creditsCalculateAvailableMoney() {
        let credits = OpenRouterCredits(response: JSONValue.parse(#"{"data":{"total_credits":5,"total_usage":1.25}}"#)!)
        #expect(credits.purchased == 5)
        #expect(credits.used == 1.25)
        #expect(credits.balance == 3.75)
    }

    @Test func githubSecretUsesASealedBox() throws {
        var publicKey = [UInt8](repeating: 0, count: Int(crypto_box_publickeybytes()))
        var secretKey = [UInt8](repeating: 0, count: Int(crypto_box_secretkeybytes()))
        #expect(sodium_init() >= 0)
        #expect(crypto_box_keypair(&publicKey, &secretKey) == 0)
        let encoded = try GitHubSealedBox.encrypt("private-value", publicKeyBase64: Data(publicKey).base64EncodedString())
        let cipher = try #require(Data(base64Encoded: encoded))
        #expect(cipher.count == "private-value".utf8.count + Int(crypto_box_sealbytes()))
        var clear = [UInt8](repeating: 0, count: cipher.count - Int(crypto_box_sealbytes()))
        let opened = cipher.withUnsafeBytes { bytes in
            crypto_box_seal_open(&clear, bytes.bindMemory(to: UInt8.self).baseAddress!, UInt64(cipher.count), &publicKey, &secretKey)
        }
        #expect(opened == 0)
        #expect(String(decoding: clear, as: UTF8.self) == "private-value")
    }

    @Test func oldJobRecordsDecodeAndCheckpointAsRestartableState() async throws {
        let id = UUID()
        let old = Data("""
        {"format":1,"id":"\(id.uuidString)","status":"running","title":"Old job","state":{},"createdAt":"2026-10-28T00:00:00Z","updatedAt":"2026-10-28T00:00:00Z"}
        """.utf8)
        let decoded = try JSONCoding.decoder().decode(JobRecord.self, from: old)
        #expect(decoded.targetRepo == nil)
        #expect(decoded.steps.isEmpty)
        #expect(decoded.cumulativeCost == 0)

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("maipag-jobs-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = JobStore(dataDirectory: root)
        var job = JobRecord(title: "Restart me", targetRepo: RepoRef(owner: "octo", name: "repo"), targetRef: "main", defaultBranch: "main")
        job.steps = [JobStepRecord(title: "First", status: .done)]
        _ = try await store.create(job)
        let stopped = try await store.stop(job.id)
        #expect(stopped.status == .stopped)
        let resumed = try await store.resume(job.id)
        #expect(resumed.status == .queued)
        #expect(resumed.steps.first?.status == .done)

        var workflow = WorkflowCheckpoint(workflowID: "full-feature", request: "Build it")
        workflow.statuses["requirements"] = .completed
        workflow.statuses["implementation"] = .running
        workflow.pendingQuestion = WorkflowQuestion(nodeID: "approval", text: "Continue?", options: ["Continue", "Stop"])
        let workflowDefinition = WorkflowDefinition(id: "full-feature", name: "Full", summary: "", steps: [
            .agent("requirements", title: "Requirements", agent: "planner", instruction: "Plan"),
            .agent("implementation", title: "Implementation", agent: "coder", instruction: "Build"),
        ], isApproved: true)
        _ = try await store.update(job.id) { record in
            let data = try JSONCoding.encoder().encode(workflowDefinition)
            var state = record.state.objectValue ?? [:]
            state["workflowDefinition"] = JSONValue.parse(data)
            record.state = .object(state)
        }
        _ = try await store.checkpointWorkflow(job.id, checkpoint: workflow)
        let restored = try #require(await store.workflowCheckpoint(job.id))
        #expect(restored.workflowID == "full-feature")
        #expect(restored.statuses["requirements"] == .completed)
        #expect(await store.load(job.id)?.status == .needsAnswer)
        #expect(await store.load(job.id)?.steps.map(\.status) == [.done, .running])

        workflow.isCancelled = true
        workflow.pendingQuestion = nil
        workflow.statuses["implementation"] = .cancelled
        _ = try await store.checkpointWorkflow(job.id, checkpoint: workflow)
        _ = try await store.resume(job.id)
        let resumable = try #require(await store.workflowCheckpoint(job.id))
        #expect(!resumable.isCancelled)
        #expect(resumable.statuses["requirements"] == .completed)
        #expect(resumable.statuses["implementation"] == .pending)
    }
    @Test func registryPaginationOAuthAndConnectorNamesAreExact() async throws {
        final class Transport: HTTPTransport, @unchecked Sendable {
            let lock = NSLock(); var requests: [HTTPRequest] = []
            func send(_ request: HTTPRequest) async throws -> HTTPResponse {
                lock.withLock { requests.append(request) }
                if request.url.path.contains("oauth-protected-resource") {
                    return HTTPResponse(status: 200, body: Data(#"{"resource":"https://mcp.example.com/mcp","authorization_servers":["https://auth.example.com"],"scopes_supported":["tools.read"]}"#.utf8))
                }
                if request.url.path.contains("oauth-authorization-server") {
                    return HTTPResponse(status: 200, body: Data(#"{"issuer":"https://auth.example.com","authorization_endpoint":"https://auth.example.com/authorize","token_endpoint":"https://auth.example.com/token","registration_endpoint":"https://auth.example.com/register","scopes_supported":["tools.read"]}"#.utf8))
                }
                if request.url.path == "/token" {
                    return HTTPResponse(status: 200, body: Data(#"{"access_token":"rotated","expires_in":3600}"#.utf8))
                }
                let body = #"{"servers":[{"server":{"name":"com.github/github-mcp","title":"GitHub","description":"GitHub tools","version":"1.0","remotes":[{"type":"streamable-http","url":"https://example.com/mcp"}],"packages":[{"registryType":"npm","identifier":"@modelcontextprotocol/server-github","version":"1.0"}]},"_meta":{"io.modelcontextprotocol.registry/official":{"status":"active","isLatest":true}}}],"metadata":{"nextCursor":"next:1","count":1}}"#
                return HTTPResponse(status: 200, body: Data(body.utf8))
            }
            func stream(_ request: HTTPRequest) async throws -> HTTPStreamResponse { HTTPStreamResponse(status: 404, headers: [:], body: AsyncThrowingStream { $0.finish() }) }
        }
        let transport = Transport()
        let page = try await MCPRegistryClient(transport: transport).page(search: "github", cursor: "before:1", limit: 5)
        #expect(page.servers.first?.displayName == "GitHub")
        #expect(page.servers.first?.supportsPhone == true && page.servers.first?.supportsAutonomous == true)
        #expect(page.nextCursor == "next:1")
        let query = try #require(URLComponents(url: transport.requests[0].url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(query.first { $0.name == "version" }?.value == "latest")
        #expect(query.first { $0.name == "search" }?.value == "github")
        #expect(query.first { $0.name == "cursor" }?.value == "before:1")

        let authorization = try await MCPOAuthClient(transport: transport).authorizationRequest(endpoint: URL(string: "https://mcp.example.com/mcp")!, requestedScopes: ["tools.read"])
        let authQuery = URLComponents(url: authorization.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(authQuery.first { $0.name == "client_id" }?.value == MCPOAuthClient.clientMetadataURL.absoluteString)
        #expect(authQuery.first { $0.name == "resource" }?.value == "https://mcp.example.com/mcp")
        #expect(authQuery.first { $0.name == "state" }?.value == authorization.state)
        #expect(authQuery.first { $0.name == "code_challenge_method" }?.value == "S256")
        let expiring = ConnectorCredential(accessToken: "old", refreshToken: "refresh", expiresAt: Date(), clientID: "client", scopes: ["tools.read"])
        let refreshed = try await MCPOAuthClient(transport: transport).refresh(expiring, server: authorization.server, resource: authorization.resource)
        #expect(refreshed.accessToken == "rotated")
        #expect(refreshed.refreshToken == "refresh")
        #expect(refreshed.scopes == ["tools.read"])
        #expect(refreshed.needsRefresh() == false)
        #expect(ConnectorToolDefinition.namespace(server: "GitHub Cloud", tool: "Search-Repositories") == "mcp_github_cloud_search_repositories")
        #if os(Linux)
        let npm = RegistryServer.Package(registryType: "npm", identifier: "@modelcontextprotocol/server-github", version: "1.0")
        #expect(try AutonomousStdioConnector.command(for: npm) == ["npx", "--yes", "@modelcontextprotocol/server-github@1.0"])
        #expect(throws: ToolInputError.self) {
            try AutonomousStdioConnector.command(for: .init(registryType: "npm", identifier: "bad\npackage"))
        }
        #endif
    }

    @Test func pictureRoutingAndWebPreviewRejectTraversal() throws {
        let freeVision = ModelInfo(id: "vision/free:free", name: "Vision Free", promptPrice: 0, completionPrice: 0, inputModalities: ["text", "image"], outputModalities: ["text"], supportedParameters: ["tools"], created: Date(timeIntervalSince1970: 2))
        let textOnly = ModelInfo(id: "text/paid", name: "Text", inputModalities: ["text"], outputModalities: ["text"], supportedParameters: ["tools"], created: Date(timeIntervalSince1970: 3))
        let route = ModelRouter.route(choice: .auto, difficulty: .normal, thinking: .medium, account: AccountState(isFreeTier: true), catalogue: [freeVision.id: freeVision, textOnly.id: textOnly], requiresImageInput: true)
        #expect(route.model == freeVision.id)
        let staticSite = WebProjectDetector.detect(paths: ["index.html", "assets/app.js"])
        #expect(staticSite?.kind == .staticSite && staticSite?.entryPath == "index.html")
        let built = WebProjectDetector.detect(paths: ["package.json"], packageJSON: Data(#"{"scripts":{"build":"vite build"}}"#.utf8))
        #expect(built?.buildCommand == "npm run build")
        #expect(throws: WebPreviewError.self) { try PreviewPath.relativePath(for: URL(string: "maipag-preview://site/%2e%2e/secret")!, root: "", spaFallback: "index.html") }
        #expect(PreviewPath.mimeType(for: "app.js") == "text/javascript")
    }
}

@Suite("Server-sent events")
struct ServerSentEventTests {
    @Test func splitsEventsAcrossArbitraryChunks() {
        let stream = ": OPENROUTER PROCESSING\n\ndata: {\"a\":1}\n\ndata: {\"b\":\r\ndata: 2}\r\n\r\ndata: [DONE]\n\n"
        let bytes = Array(stream.utf8)
        for size in [1, 2, 3, 7, 64] {
            var parser = ServerSentEventParser()
            var events: [String] = []
            var index = 0
            while index < bytes.count {
                let end = min(index + size, bytes.count)
                events += parser.feed(Data(bytes[index..<end]))
                index = end
            }
            events += parser.finish()
            #expect(events == ["{\"a\":1}", "{\"b\":\n2}", "[DONE]"], "chunk size \(size)")
        }
    }

    @Test func keepsMultiByteCharactersWhole() {
        let text = "data: héllo 👋\n\n"
        var parser = ServerSentEventParser()
        var events: [String] = []
        for byte in text.utf8 { events += parser.feed(Data([byte])) }
        #expect(events == ["héllo 👋"])
    }

    @Test func finalEventWithoutBlankLineCounts() {
        var parser = ServerSentEventParser()
        #expect(parser.feed(Data("data: last".utf8)).isEmpty)
        #expect(parser.finish() == ["last"])
    }
}

@Suite("Glob patterns")
struct GlobTests {
    @Test(arguments: [
        ("*.swift", "App/Sources/Main.swift", true),
        ("*.swift", "README.md", false),
        ("App/**/*.swift", "App/Sources/Deep/Main.swift", true),
        ("App/**/*.swift", "App/Main.swift", true),
        ("App/*.swift", "App/Sources/Main.swift", false),
        ("**/test_*.py", "a/b/test_x.py", true),
        ("{App,Tests}/**", "Tests/x/y.txt", true),
        ("{App,Tests}/**", "Docs/x.txt", false),
        ("src/[a-c]*.ts", "src/beta.ts", true),
        ("src/[!a-c]*.ts", "src/beta.ts", false),
        ("?.md", "a.md", true),
        ("docs/**", "docs/index.html", true),
        ("*.{png,jpg}", "assets/logo.png", true),
    ])
    func matches(pattern: String, path: String, expected: Bool) {
        #expect(Glob(pattern).matches(path) == expected)
    }
}
