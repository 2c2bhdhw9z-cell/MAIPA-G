import Foundation
import Testing
@testable import AgentCore

private final class Build77MockTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var seenRequests: [HTTPRequest] = []
    let handler: @Sendable (HTTPRequest) -> HTTPResponse

    init(_ handler: @escaping @Sendable (HTTPRequest) -> HTTPResponse) {
        self.handler = handler
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        lock.withLock { seenRequests.append(request) }
        return handler(request)
    }

    func stream(_ request: HTTPRequest) async throws -> HTTPStreamResponse {
        lock.withLock { seenRequests.append(request) }
        let res = handler(request)
        return HTTPStreamResponse(
            status: res.status,
            headers: res.headers,
            body: AsyncThrowingStream { continuation in
                if !res.body.isEmpty { continuation.yield(res.body) }
                continuation.finish()
            }
        )
    }
}

private struct Build77FixedGitHubToken: GitHubTokenProvider {
    func installationToken() async throws -> String { "ghs_test_secret_token" }
    func userToken() async throws -> String { "ghs_test_secret_token" }
}

@Suite("Build 77 — Kiro Sub-Agents, 5-Node Workflows, 250 MB Streaming, Surgical Diffs, & Multi-Pass Fixes")
struct Build77Tests {
    @Test("AttachmentStore supports 250 MB limit, zero-copy URL streaming, and byte-slice reads")
    func attachmentStore250MBStreamingAndSlicing() async throws {
        #expect(AttachmentStore.maximumAttachmentBytes == 250 * 1_048_576)

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("maipag-b77-att-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AttachmentStore(dataDirectory: root)

        let sourceURL = root.appendingPathComponent("temp-upload.log")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let sample = String(repeating: "Line-0123456789\n", count: 400)
        try Data(sample.utf8).write(to: sourceURL)

        let imported = try await store.importFile(
            at: sourceURL,
            name: "build-output.log",
            mimeType: "text/plain",
            kind: .text
        )
        #expect(imported.bytes == sample.utf8.count)

        let sliceResult = try await store.readSlice(for: imported, offsetBytes: 16, maxBytes: 32)
        #expect(sliceResult.totalBytes == sample.utf8.count)
        #expect(String(data: sliceResult.data, encoding: .utf8) == "Line-0123456789\nLine-0123456789\n")

        let readTool = ReadAttachmentTool(attachments: [imported], store: store)
        let output = try await readTool.run(
            arguments: ["name": "build-output.log", "offset": 0, "limit": 1024],
            progress: { _ in }
        )
        #expect(output.forModel.contains("Line-0123456789"))
    }

    @Test("Surgical edit_file, append_file, unified @@ diffs, vision read_file, and ChangeWorkspace rebase preserve staged edits")
    func surgicalEditAppendUnifiedDiffVisionReadAndRebase() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("maipag-b77-ws-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let github = FakeGitHub()
        let onePxPNG = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==")!
        github.commitRemotely([
            "src/main.swift": Data("let a = 1\nlet b = 2\nlet c = 3\nprint(a + b + c)\n".utf8),
            "assets/logo.png": onePxPNG,
        ])
        let commit1 = try #require(github.head)
        let base1 = RepoWorkspace(
            repo: RepoRef(owner: "octo", name: "MAIPA-G-data"),
            branch: "main",
            commit: commit1,
            github: github.client,
            store: SnapshotStore(root: root)
        )
        let changes = ChangeWorkspace(base: base1)

        // Vision ReadFileTool returns inline image attachment + PNG dimensions
        let visionRead = ReadFileTool(workspace: base1)
        let imgOut = try await visionRead.run(arguments: ["path": "assets/logo.png"], progress: { _ in })
        #expect(imgOut.inlineImages.count == 1)
        #expect(imgOut.forModel.contains("1×1"))

        // Surgical single-occurrence replacement via EditFileTool + AppendFileTool
        let auth = ChangeAuthorization(request: "Update src/main.swift")
        let editTool = EditFileTool(workspace: changes, authorization: auth)
        _ = try await editTool.run(
            arguments: ["path": "src/main.swift", "old_text": "let b = 2", "new_text": "let b = 42"],
            progress: { _ in }
        )
        let appendTool = AppendFileTool(workspace: changes, authorization: auth)
        _ = try await appendTool.run(
            arguments: ["path": "src/main.swift", "content": "print(\"done\")\n"],
            progress: { _ in }
        )

        let diff = await changes.stagedDiff()
        #expect(diff.contains("@@"))
        #expect(diff.contains("-let b = 2"))
        #expect(diff.contains("+let b = 42"))
        #expect(diff.contains("+print(\"done\")"))
        #expect(await changes.hasStagedChanges() == true)

        // Rebasing onto a newer remote commit preserves unsaved staged work
        github.commitRemotely([
            "src/main.swift": Data("let a = 1\nlet b = 2\nlet c = 3\nprint(a + b + c)\n".utf8),
            "README.md": Data("# Hello\n".utf8),
        ])
        let commit2 = try #require(github.head)
        let base2 = base1.advancing(toCommit: commit2)
        let rebased = await changes.rebased(onto: base2)
        #expect(rebased.base.commit == commit2)
        #expect(await rebased.hasStagedChanges() == true)
        if case .text(let merged, _) = try await rebased.read("src/main.swift") {
            #expect(merged.contains("let b = 42"))
            #expect(merged.contains("print(\"done\")"))
        } else {
            Issue.record("Expected staged text after rebase")
        }
    }

    @Test("Kiro 5 sub-agents, .kiro/agents loader, and CreateCustomAgentTool preserve BuiltInAgents.all == 13")
    func kiroSubagentsAndRepoLoader() async throws {
        #expect(BuiltInAgents.all.count == 13)
        let kiroIDs = Set(BuiltInAgents.kiroSubagents.map(\.id))
        #expect(kiroIDs == ["context-gatherer", "general-task-execution", "semantic-reviewer", "introspect", "custom-agent-creator"])

        let parsedJSON = RepoAgentLoader.parseJSONAgent(
            #"{"id":"security-auditor","displayName":"Security Auditor","description":"Audits auth flows","readOnly":true}"#,
            filePath: ".kiro/agents/security-auditor.json"
        )
        #expect(parsedJSON?.id == "repo:security-auditor")
        #expect(parsedJSON?.behavior == .reportOnly)

        let parsedMD = RepoAgentLoader.parseMarkdownAgent(
            """
            ---
            name: Migration Helper
            description: Updates database migrations
            tools: read_file, edit_file
            ---
            Carefully inspect schema files before editing.
            """,
            filePath: ".kiro/agents/migration-helper.md"
        )
        #expect(parsedMD?.id == "repo:migration-helper")
        #expect(parsedMD?.behavior == .changesAllowed)

        let creatorTool = CreateCustomAgentTool { draft in draft }
        let out = try await creatorTool.run(
            arguments: [
                "name": "API Verifier",
                "summary": "Checks REST endpoints",
                "instructions": "Verify status codes and schemas.",
                "read_only": true,
            ],
            progress: { _ in }
        )
        #expect(out.forModel.contains("API Verifier"))
    }

    @Test("Kiro 5-node WorkflowEngine validates limits, wraps {{stepId.output}} boundaries, runs watch/parallel, steers, and updates remaining steps")
    func kiroFiveNodeWorkflowEngine() async throws {
        let workflow = WorkflowDefinition(
            id: "b77-flow",
            name: "Audit & Verify",
            summary: "End-to-end 5-node test",
            steps: [
                WorkflowNode(
                    id: "gather",
                    kind: .agent,
                    title: "Gather context",
                    agentID: "context-gatherer",
                    instruction: "Find key modules.",
                    modelID: "anthropic/claude-sonnet-4.6",
                    effortLevel: .max
                ),
                .parallel(
                    "fanout",
                    title: "Parallel checks",
                    joinPolicy: .any,
                    agents: [
                        .agent("fast-branch", title: "Fast branch", agent: "semantic-reviewer", instruction: "Inspect {{gather.output}}"),
                        .agent("other-branch", title: "Second branch", agent: "introspect", instruction: "Check status"),
                    ]
                ),
                .watch(
                    "poll-ready",
                    title: "Wait for green",
                    instruction: "Check CI status",
                    containsText: "CI_GREEN",
                    maximumChecks: 3,
                    pollIntervalSeconds: 0,
                    agent: "context-gatherer"
                ),
            ],
            isApproved: true
        )

        let validAgents = Set(BuiltInAgents.allIncludingKiroSubagents.map(\.id))
        #expect(workflow.validationErrors(agentIDs: validAgents).isEmpty)

        // Reject Free AIs on per-step modelID
        var invalidFree = workflow
        invalidFree.steps[0].modelID = ModelChoice.freeID
        #expect(!invalidFree.validationErrors(agentIDs: validAgents).isEmpty)

        actor CaptureBox {
            var prompts: [String] = []
            var contexts: [String] = []
            var models: [String?] = []
            var watchCount = 0
            func record(task: String, context: String, model: String?) {
                prompts.append(task)
                contexts.append(context)
                models.append(model)
            }
            func nextWatch() -> Int {
                watchCount += 1
                return watchCount
            }
        }
        let box = CaptureBox()

        let engine = WorkflowEngine(
            definition: workflow,
            defaultModelID: "openai/gpt-5.4",
            defaultEffort: .max,
            runner: { invocation in
                await box.record(task: invocation.task, context: invocation.context, model: invocation.preferredModelID)
                if invocation.task.contains("Find key modules") {
                    if let sendTool = invocation.tools.first(where: { $0.name == "send_message" }) {
                        _ = try? await sendTool.run(arguments: ["message": "Context gathered"], progress: { _ in })
                    }
                    return AgentExecutionResult(output: "MODULE_A_READY", model: invocation.preferredModelID, cost: 0.01)
                }
                if invocation.task.contains("Check CI status") {
                    let attempt = await box.nextWatch()
                    return AgentExecutionResult(output: attempt >= 2 ? "All checks CI_GREEN" : "Pending", model: invocation.preferredModelID, cost: 0.005)
                }
                return AgentExecutionResult(output: "Branch OK", model: invocation.preferredModelID, cost: 0.01)
            }
        )

        try await engine.steer("Prefer concise bullet points.")
        let outcome = await engine.run(request: "Audit authentication")
        guard case .completed(let cp) = outcome else {
            Issue.record("Expected workflow completion, got \(outcome)")
            return
        }
        #expect(cp.sentMessages.count == 1)
        #expect(cp.sentMessages[0].message == "Context gathered")
        #expect(cp.repeatIterations["poll-ready"] == 2)

        let prompts = await box.prompts
        let contexts = await box.contexts
        // Verify <workflow_prompt>, steering notes, and <workflow_step_output> untrusted boundary
        #expect(contexts.contains(where: { $0.contains("<workflow_prompt>") && $0.contains("Prefer concise bullet points.") }))
        #expect(prompts.contains(where: { $0.contains("<workflow_step_output step=\"gather\">") && $0.contains("MODULE_A_READY") }))
    }

    @Test("Workstation tools, Inkling harness headers, stream deduplication, pure image catalogue, WebPageReader JSON, and authenticated IPA download")
    func workstationInklingStreamingImagesWebAndArtifactDownload() async throws {
        // 1. Inkling allowlisted harness headers
        #expect(OpenRouterClient.requiresAllowlistedHarnessHeaders("thinkingmachines/inkling:free") == true)
        #expect(OpenRouterClient.requiresAllowlistedHarnessHeaders("anthropic/claude-opus-4.6") == false)

        // 2. Streamed tool-name deduplication (`read_fileread_file` -> `read_file` when provider repeats full name)
        var acc = StreamAccumulator()
        acc.apply(StreamChunk(toolCallDeltas: [StreamChunk.ToolCallDelta(index: 0, id: "call_1", name: "read_file", arguments: "{\"pa")]))
        acc.apply(StreamChunk(toolCallDeltas: [StreamChunk.ToolCallDelta(index: 0, id: nil, name: "read_file", arguments: "th\":\"a.swift\"}")]))
        #expect(acc.toolCalls.count == 1)
        #expect(acc.toolCalls[0].function.name == "read_file")
        #expect(acc.toolCalls[0].function.arguments == "{\"path\":\"a.swift\"}")

        // 3. Inline chat `message.images` accumulation
        acc.apply(StreamChunk(imageDataURLs: ["data:image/png;base64,iVBORw0KGgo="]))
        #expect(acc.imageDataURLs == ["data:image/png;base64,iVBORw0KGgo="])

        // 4. Pure image model flags
        let flux = ModelInfo(
            id: "black-forest-labs/flux.2-pro",
            name: "Black Forest Labs: FLUX.2 Pro",
            inputModalities: ["text"],
            outputModalities: ["image"]
        )
        #expect(flux.generatesImages == true)
        #expect(flux.isChatModel == false)
        #expect(flux.isPureImageModel == true)
        #expect(flux.isSelectableModel == true)

        // 5. Workstation AI tools round-trip (`write_workstation_file` -> `list` -> `read`)
        let wsDir = FileManager.default.temporaryDirectory.appendingPathComponent("maipag-b77-wks-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: wsDir) }
        let store = AttachmentStore(dataDirectory: wsDir)
        actor Box {
            var items: [WorkstationFileItem] = []
            func add(_ ref: AttachmentReference) {
                items.append(WorkstationFileItem(id: ref.id.uuidString, name: ref.name, mimeType: ref.mimeType, byteCount: ref.bytes, source: "workstation", attachment: ref))
            }
            func all() -> [WorkstationFileItem] { items }
        }
        let wsBox = Box()
        let writeTool = WriteWorkstationFileTool(store: store) { ref, _ in await wsBox.add(ref) }
        _ = try await writeTool.run(arguments: ["name": "chart.mmd", "content": "graph TD; A-->B;"], progress: { _ in })
        let listTool = ListWorkstationFilesTool { await wsBox.all() }
        let listed = try await listTool.run(arguments: [:], progress: { _ in })
        #expect(listed.forModel.contains("chart.mmd"))
        let readTool = ReadWorkstationFileTool(store: store, listProvider: { await wsBox.all() })
        let readOut = try await readTool.run(arguments: ["name": "chart.mmd"], progress: { _ in })
        #expect(readOut.forModel.contains("graph TD; A-->B;"))

        // 6. BinaryImageInspector PNG dimensions & SensitiveDataRedactor expanded coverage
        let onePxPNG = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==")!
        let meta = BinaryImageInspector.inspect(onePxPNG, path: "icon.png")
        #expect(meta?.mimeType == "image/png")
        #expect(meta?.dimensions?.width == 1 && meta?.dimensions?.height == 1)

        let redacted = SensitiveDataRedactor().redact("token=figd_1234567890abcdefghijklmnop and key=AIzaSyA12345678901234567890123456789012")
        #expect(!redacted.contains("figd_123456"))
        #expect(!redacted.contains("AIzaSyA12345"))

        // 7. WebPageReader JSON formatting & BuiltinIntegrationFactory "x" alias
        let jsonTransport = Build77MockTransport { _ in
            HTTPResponse(status: 200, headers: ["content-type": "application/json"], body: Data(#"{"status":"ok","items":[1,2]}"#.utf8))
        }
        let page = try await WebPageReader(transport: jsonTransport).read(URL(string: "https://api.example.com/v1/status")!)
        #expect(page.text.contains("\"status\""))

        let xConfig = ConnectorConfiguration(
            serverID: "builtin:x",
            displayName: "X",
            kind: .builtin,
            launchValues: ["provider": "x"],
            secretNames: ["api_key"]
        )
        let xDefs = BuiltinIntegrationFactory.definitions(for: xConfig)
        #expect(!xDefs.isEmpty)

        // 8. Authenticated GitHub Actions artifact download strips Authorization on cross-host 302 redirect
        let artifactTransport = Build77MockTransport { req in
            if req.url.host == "api.github.com" {
                return HTTPResponse(
                    status: 302,
                    headers: ["Location": "https://pipelines.actions.githubusercontent.com/signed-artifact.zip"],
                    body: Data()
                )
            }
            return HTTPResponse(status: 200, headers: [:], body: Data("PK-FAKE-ZIP-BYTES".utf8))
        }
        let ghClient = GitHubClient(transport: artifactTransport, tokens: Build77FixedGitHubToken())
        let dest = wsDir.appendingPathComponent("artifact.zip")
        try await ghClient.downloadAuthenticatedArtifact(
            at: "https://api.github.com/repos/acme/app/actions/artifacts/99/zip",
            to: dest
        )
        #expect(try Data(contentsOf: dest) == Data("PK-FAKE-ZIP-BYTES".utf8))
        let requests = artifactTransport.seenRequests
        #expect(requests.count == 2)
        #expect(requests[0].headers["Authorization"]?.contains("ghs_test_secret_token") == true)
        #expect(requests[1].headers["Authorization"] == nil)
    }
}
