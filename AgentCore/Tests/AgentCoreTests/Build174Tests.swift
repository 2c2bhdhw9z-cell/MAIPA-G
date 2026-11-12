import Foundation
import Testing
@testable import AgentCore

/// The owner's build 173 reports (11 November 2026): pictures failing on a gateway that was down,
/// the AI never saving memories, and "Lost contact with your computer".
@Suite("Build 174 fixes")
struct Build174Tests {
    #if os(Linux)
    static let onLinux = true
    #else
    static let onLinux = false
    #endif

    @Test("A command that starts a server in the background finishes when its shell does", .enabled(if: onLinux))
    func backgroundServerDoesNotHoldTheCommand() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("maipa-g-bg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let control = ComputerControl.local(machine: "test", home: home)
        let started = Date()
        let output = try await control.run("(setsid nohup sleep 25 > /dev/null 2>&1 &) ; (sleep 25 &) ; echo started")
        #expect(output.contains("started"))
        #expect(Date().timeIntervalSince(started) < 10)
    }

    @Test("A gateway's 'temporarily unable … retry shortly' 500 counts as a service that's down for a moment")
    func temporaryGatewayErrorIsTemporary() {
        let body = Data(#"{"error":{"code":"500","message":"The service is temporarily unable to serve this request. Please retry shortly."}}"#.utf8)
        let error = OpenRouterAPIError(status: 500, body: body, headers: [:], providerName: "TeamoRouter")
        #expect(error.kind == .providerFailed)
        #expect(error.isTemporary)
        let broken = OpenRouterAPIError(status: 400, body: Data(#"{"error":{"code":"400","message":"bad prompt"}}"#.utf8), headers: [:], providerName: "TeamoRouter")
        #expect(!broken.isTemporary)
    }

    @Test("The picture models are ranked best first, the same family on another provider next")
    func rankedPictureModels() {
        func model(_ id: String, created: Double) -> ModelInfo {
            ModelInfo(id: id, name: id, promptPrice: 0.000001, completionPrice: 0.00001, inputModalities: ["image", "text"],
                      outputModalities: ["image", "text"], created: Date(timeIntervalSince1970: created))
        }
        let models = [
            model("oneprovider::flux-2-pro", created: 3),
            model("teamorouter::gemini-3-pro-image", created: 2),
            model("oneprovider::gemini-3-pro-image", created: 1),
        ]
        let ranked = ImageModelChooser.ranked(for: .edit, among: models).map(\.id)
        #expect(ranked.prefix(2) == ["teamorouter::gemini-3-pro-image", "oneprovider::gemini-3-pro-image"])
        #expect(ImageModelChooser.best(for: .edit, among: models)?.id == ranked.first)
    }

    @Test("A follow-up edit is sent with the changes asked for before it")
    func followUpEditCarriesEarlierRequests() {
        let prompt = QuickPictureRequest.edit("No, I said purple gold.").prompt(earlier: ["Now a purple gold."])
        #expect(prompt.hasPrefix("Change this picture: No, I said purple gold."))
        #expect(prompt.contains("\"Now a purple gold.\""))
        #expect(!prompt.contains(".."))
        #expect(QuickPictureRequest.edit("make it red").prompt == QuickPictureRequest.edit("make it red").prompt(earlier: []))
    }

    @Test("The AI is told to save preferences and corrections to memories, even before there are any")
    func memoryInstructionsAreProactive() {
        let prompt = SystemPrompt.make(userLogin: nil, repo: nil)
        #expect(prompt.contains("call `add_memory` in that same turn without asking"))
        #expect(AddMemoryTool(store: ProductStore<MemoryRecord>(dataDirectory: FileManager.default.temporaryDirectory, folder: "m")).spec.function.description.contains("without asking"))
    }

    @Test("Memories the AI saves on the computer come back with the reply's state")
    func memoriesTravelBack() throws {
        let saved = MemoryRecord(text: "No pull requests.", source: .ai)
        let state = VMTurnState(id: "r", seq: 1, phase: .running, turn: AssistantTurn(), memories: [saved])
        let decoded = try VMCoding.unpack(VMTurnState.self, from: VMCoding.pack(state))
        #expect(decoded.memories?.map(\.text) == ["No pull requests."])
        #expect(VMTurnRunner.promptNote(machine: "m", hasConnectors: true).contains("Sub-agents (`invoke_sub_agent`) and memories work here"))
    }
}

extension Build174Tests {
    @Test("A command's output, exit code and slow steps all still arrive", .enabled(if: onLinux))
    func commandsStillRunToTheEnd() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("maipa-g-cmd-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let control = ComputerControl.local(machine: "test", home: home)
        let output = try await control.run("echo one; sleep 1.5; echo \"two $0\"; case x in x) echo three ;; esac # trailing comment")
        #expect(output.contains("one") && output.contains("two") && output.contains("three"))
        let failed = try await control.run("echo before; exit 3")
        #expect(failed.contains("before") && failed.contains("(exit code 3)"), "\(failed)")
    }
}

/// Videos through OneProvider when OpenRouter has no credit (owner, 11 November 2026).
@Suite("Videos through the gateways")
struct GatewayVideoTests {
    final class GatewayVideoTransport: HTTPTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var _requests: [HTTPRequest] = []
        var requests: [HTTPRequest] { lock.withLock { _requests } }
        var openAIRouteMissing = true

        func send(_ request: HTTPRequest) async throws -> HTTPResponse {
            lock.withLock { _requests.append(request) }
            let url = request.url.absoluteString
            if url.hasPrefix("https://openrouter.ai/") {
                return HTTPResponse(status: 402, headers: [:], body: Data(#"{"error":{"code":402,"message":"Insufficient credits"}}"#.utf8))
            }
            if url == "https://api.oneprovider.dev/v1/videos", request.method == "POST" {
                return openAIRouteMissing
                    ? HTTPResponse(status: 404, headers: [:], body: Data(#"{"error":{"message":"The requested API endpoint does not exist"}}"#.utf8))
                    : HTTPResponse(status: 200, headers: [:], body: Data(#"{"id":"v1","status":"queued"}"#.utf8))
            }
            if url == "https://api.oneprovider.dev/v1/videos/v1" {
                return HTTPResponse(status: 200, headers: [:], body: Data(#"{"id":"v1","status":"completed"}"#.utf8))
            }
            if url == "https://api.oneprovider.dev/v1/videos/v1/content" {
                return HTTPResponse(status: 200, headers: ["content-type": "video/mp4"], body: Data("openai-mp4".utf8))
            }
            if url == "https://api.oneprovider.dev/v1/video/generations", request.method == "POST" {
                return HTTPResponse(status: 200, headers: [:], body: Data(#"{"task_id":"t9","status":"queued"}"#.utf8))
            }
            if url == "https://api.oneprovider.dev/v1/video/generations/t9" {
                return HTTPResponse(status: 200, headers: [:], body: Data(#"{"task_id":"t9","status":"succeeded","url":"https://cdn.example.com/t9.mp4"}"#.utf8))
            }
            if url == "https://cdn.example.com/t9.mp4" {
                return HTTPResponse(status: 200, headers: ["content-type": "video/mp4"], body: Data("task-mp4".utf8))
            }
            return HTTPResponse(status: 404, headers: [:], body: Data())
        }
        func stream(_ request: HTTPRequest) async throws -> HTTPStreamResponse {
            HTTPStreamResponse(status: 500, headers: [:], body: AsyncThrowingStream { $0.finish() })
        }
    }

    static let oneProvider = AIProviderEndpoint(id: "oneprovider", name: "OneProvider", baseURL: "https://api.oneprovider.dev/v1", apiKey: "sk-one")

    @Test("OneProvider's Kling models are offered for videos, next to OpenRouter's")
    func oneProviderVideoModels() {
        let ids = AIProviderGateway.videoModels(for: Self.oneProvider).map(\.id)
        #expect(ids == ["oneprovider::kling-3.0", "oneprovider::kling-3.0-turbo"])
        let teamo = AIProviderEndpoint(id: "teamorouter", name: "TeamoRouter", baseURL: "https://api.teamorouter.com/v1", apiKey: "sk-teamo-x")
        #expect(AIProviderGateway.videoModels(for: teamo).isEmpty)
    }

    @Test("With no OpenRouter credit the video is made on OneProvider, by the task route, without sending the key to the storage host")
    func fallsBackToOneProvider() async throws {
        let transport = GatewayVideoTransport()
        let client = OpenRouterClient(transport: transport, apiKey: "or-key", extraProviders: [Self.oneProvider])
        let store = AttachmentStore(dataDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("maipa-g-video-\(UUID().uuidString)"))
        let models = [VideoModelInfo(id: "google/veo-3.1", name: "Veo 3.1")] + AIProviderGateway.videoModels(for: Self.oneProvider)
        let tool = GenerateVideoTool(client: client, store: store, availableImages: [], models: { models })
        let output = try await tool.runApproved(arguments: ["prompt": "a ball bounces"]) { _ in }
        #expect(output.generatedImages.first?.model == "oneprovider::kling-3.0")
        #expect(output.forModel.contains("couldn't"))
        let cdn = transport.requests.first { $0.url.host == "cdn.example.com" }
        #expect(cdn != nil)
        #expect(cdn?.headers["Authorization"] == nil)
        let start = transport.requests.first { $0.url.path.hasSuffix("/video/generations") }
        #expect(start?.headers["Authorization"] == "Bearer sk-one")
    }

    @Test("A gateway with OpenAI's /videos route is asked there and the video downloaded from it")
    func openAIStyleRoute() async throws {
        let transport = GatewayVideoTransport()
        transport.openAIRouteMissing = false
        let video = try await AIProviderGateway.generateVideo(prompt: "waves", rawModelID: "kling-3.0", duration: 5, aspectRatio: "16:9", firstFrame: nil, endpoint: Self.oneProvider, transport: transport, pollEvery: 0.01)
        #expect(video.data == Data("openai-mp4".utf8))
    }
}

/// Sub-agents the way Kiro does them (owner, 11 November 2026).
@Suite("Kiro sub-agents")
struct KiroSubAgentTests {
    static func tool(runner: @escaping AgentExecutor.Runner) -> InvokeSubAgentTool {
        let definitions = SubAgentSetup.definitions(excluding: ["introspect", "custom-agent-creator"])
        let coordinator = AgentHelperCoordinator(lead: SubAgentSetup.lead, definitions: definitions, context: "", spendLimit: nil, runner: runner)
        return InvokeSubAgentTool(lead: SubAgentSetup.lead, definitions: definitions, coordinator: coordinator)
    }

    @Test("One named sub-agent per call, with its task and a line for the person, and its report back")
    func invokesOneSubAgent() async throws {
        let tool = Self.tool { invocation in
            AgentExecutionResult(output: "Found it in \(invocation.definition.id): Sources/A.swift:12", model: "m", cost: 0.01, toolCallCount: 3, toolSummaries: ["Read A.swift"], status: "completed")
        }
        let names = tool.spec.function.parameters["properties"]?["name"]?["enum"]?.arrayValue?.compactMap(\.stringValue) ?? []
        #expect(names.contains("context-gatherer") && names.contains("general-task-execution") && names.contains("semantic-reviewer"))
        #expect(!names.contains("planner"))
        let arguments: JSONValue = ["name": "context-gatherer", "prompt": "Where is the login screen?", "explanation": "Finding the login screen before changing it."]
        let initial = tool.initialSubagents(for: arguments, callID: "c1")
        #expect(initial?.first?.explanation == "Finding the login screen before changing it.")
        #expect(initial?.first?.task == "Where is the login screen?")
        let output = try await tool.runLive(arguments: arguments, callID: "c1", existingSubagents: nil) { _ in }
        #expect(output.forModel.contains("Found it in context-gatherer"))
        #expect(output.subagents?.first?.status == .completed)
        #expect(output.subagents?.first?.explanation == "Finding the login screen before changing it.")
        #expect(output.summary == "Context Gatherer · done · 3 actions")
        #expect(SubagentTools.isSubagentTool(tool.name))
    }

    @Test("An unknown sub-agent or an empty task is explained to the AI")
    func rejectsBadCalls() async {
        let tool = Self.tool { _ in AgentExecutionResult(output: "x", cost: 0, status: "completed") }
        await #expect(throws: ToolInputError.self) { _ = try await tool.runLive(arguments: ["name": "planner", "prompt": "p", "explanation": "e"], callID: "c", existingSubagents: nil) { _ in } }
        await #expect(throws: ToolInputError.self) { _ = try await tool.runLive(arguments: ["name": "context-gatherer", "prompt": " ", "explanation": "e"], callID: "c", existingSubagents: nil) { _ in } }
    }

    @Test("A saved invoke_sub_agent call shows as its own card")
    func savedCallResolvesToOneCard() {
        var call = ToolCallRecord(id: "c9", name: "invoke_sub_agent", arguments: #"{"name":"semantic-reviewer","prompt":"Review the diff","explanation":"Checking the change."}"#, summary: "x", status: .done)
        call.result = "Looks right."
        let items = SubagentRunItem.resolvedItems(for: call)
        #expect(items.count == 1)
        #expect(items.first?.name == "Semantic Reviewer")
        #expect(items.first?.explanation == "Checking the change.")
        #expect(items.first?.status == .completed)
    }
}

extension Build174Tests {
    @Test("A script too long for one argument still runs on the computer (the bun.lock sync)", .enabled(if: onLinux))
    func longScriptsRunFromAFile() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("maipa-g-long-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let control = ComputerControl.local(machine: "test", home: home)
        let payload = String(repeating: "a", count: 300_000)
        let output = try await control.run("x='\(payload)'; echo \"length ${#x}\"; exit 4")
        #expect(output.contains("length 300000"), "\(output.prefix(300))")
        #expect(output.contains("(exit code 4)"))
    }
}

extension GatewayVideoTests {
    /// OneProvider as it answered on 12 November 2026: JSON only, a job in Kling's shape.
    final class JSONOnlyGateway: HTTPTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var _bodies: [JSONValue] = []
        var bodies: [JSONValue] { lock.withLock { _bodies } }
        var answer = #"{"code":0,"data":{"task_id":"k1","task_status":"submitted"}}"#

        func send(_ request: HTTPRequest) async throws -> HTTPResponse {
            let url = request.url.absoluteString
            if url == "https://api.oneprovider.dev/v1/videos", request.method == "POST" {
                guard request.headers["Content-Type"]?.contains("json") == true, let body = request.body.flatMap({ JSONValue.parse($0) }) else {
                    return HTTPResponse(status: 400, headers: [:], body: Data(#"{"error":{"message":"request body must be a JSON object"}}"#.utf8))
                }
                lock.withLock { _bodies.append(body) }
                return HTTPResponse(status: 200, headers: [:], body: Data(answer.utf8))
            }
            if url == "https://api.oneprovider.dev/v1/videos/k1" {
                return HTTPResponse(status: 404, headers: [:], body: Data())
            }
            if url == "https://api.oneprovider.dev/v1/video/generations/k1" {
                return HTTPResponse(status: 200, headers: [:], body: Data(#"{"data":{"task_id":"k1","task_status":"succeed","task_result":{"videos":[{"url":"https://cdn.example.com/k1.mp4"}]}}}"#.utf8))
            }
            if url == "https://cdn.example.com/k1.mp4" {
                return HTTPResponse(status: 200, headers: ["content-type": "video/mp4"], body: Data("kling-mp4".utf8))
            }
            return HTTPResponse(status: 404, headers: [:], body: Data())
        }
        func stream(_ request: HTTPRequest) async throws -> HTTPStreamResponse {
            HTTPStreamResponse(status: 500, headers: [:], body: AsyncThrowingStream { $0.finish() })
        }
    }

    @Test("A video from a picture is asked for as JSON, and a Kling-style job is found and followed")
    func jsonWithFirstFrameAndKlingJob() async throws {
        let gateway = JSONOnlyGateway()
        let frame = ImageInput(name: "p.png", mimeType: "image/png", data: Data([1, 2, 3]))
        let video = try await AIProviderGateway.generateVideo(prompt: "blobs merge", rawModelID: "kling-3.0", duration: 5, aspectRatio: "16:9", firstFrame: frame, endpoint: Self.oneProvider, transport: gateway, pollEvery: 0.01)
        #expect(video.data == Data("kling-mp4".utf8))
        #expect(gateway.bodies.first?["image"]?.stringValue?.hasPrefix("data:image/png;base64,") == true)
        #expect(gateway.bodies.first?["model"]?.stringValue == "kling-3.0")
    }

    @Test("A 200 with no job says what the gateway answered")
    func noJobSaysWhatCameBack() async {
        let gateway = JSONOnlyGateway()
        gateway.answer = #"{"object":"list","message":"queued elsewhere"}"#
        do {
            _ = try await AIProviderGateway.generateVideo(prompt: "x", rawModelID: "kling-3.0", duration: 5, aspectRatio: nil, firstFrame: nil, endpoint: Self.oneProvider, transport: gateway, pollEvery: 0.01)
            Issue.record("expected an error")
        } catch let error as OpenRouterAPIError {
            #expect(error.message.contains("queued elsewhere"))
            #expect(MediaFallback.tryAnother(error) != nil)
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test("Commands show as what they ran, like a terminal")
    func commandPreviews() {
        #expect(RunCommandTool.commandPreview("cd /home/sprite/repos/o/r && bun install --frozen-lockfile") == "bun install --frozen-lockfile")
        #expect(RunCommandTool.commandPreview("git status --short\ngit diff") == "git status --short")
        #expect(RunCommandTool.commandPreview("   ") == "a command")
        #expect(RunCommandTool.commandPreview(String(repeating: "x", count: 100)).count == 60)
    }
}

extension Build174Tests {
    @Test("The Workstation list gives the full total and kinds, pages 200 at a time, searches, and counts the repo's files")
    func workstationListPagesAndCounts() async throws {
        var items: [WorkstationFileItem] = (0..<450).map { WorkstationFileItem(id: "a\($0)", name: "photo-\($0).png", mimeType: "image/png", byteCount: 10, source: "chat_attachment") }
        items.append(WorkstationFileItem(id: "g1", name: "logo.png", mimeType: "image/png", byteCount: 10, source: "generated_image"))
        let all = items
        let tool = ListWorkstationFilesTool(listProvider: { all }, repoFileCount: { ("o/Continuum-", 1_974) })
        let first = try await tool.run(arguments: [:]) { _ in }
        #expect(first.forModel.contains("451 in total (450 attachments, 1 generated)"))
        #expect(first.forModel.contains("Showing 1–200 of 451"))
        #expect(first.forModel.contains("offset 200"))
        #expect(first.forModel.contains("1974 files of the repo o/Continuum-"))
        #expect(first.forModel.contains("2425"))
        #expect(first.forModel.split(separator: "\n").filter { $0.hasPrefix("- ") }.count == 200)
        let last = try await tool.run(arguments: ["offset": 400]) { _ in }
        #expect(last.forModel.contains("Showing 401–451 of 451"))
        let found = try await tool.run(arguments: ["query": "LOGO"]) { _ in }
        #expect(found.forModel.contains("1 match"))
        #expect(found.forModel.contains("logo.png"))
    }
}

extension Build174Tests {
    @Test("A runner that dies says why, from its log", .enabled(if: onLinux))
    func deadRunnerSaysWhy() async throws {
        let home = try ComputerRunnerTests.temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let id = VMRun.newTurnID()
        let folder = home.appendingPathComponent(VMRun.folder(id), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "starting\nFatal error: Index out of range\nmaipa-g-runner-exit 132\n".write(to: folder.appendingPathComponent("runner.log"), atomically: true, encoding: .utf8)
        let vm = VMControl(computer: ComputerControl.local(machine: "test", home: home))
        var running = AssistantTurn()
        running.status = .running
        let run = AgentRun.onComputer(VMRunHandle(id: id, control: vm), startingTurn: running, pollInterval: 200_000_000) { _ in }
        var last: AssistantTurn?
        for await event in run.events {
            if case .updated(let turn, _) = event { last = turn }
        }
        let notice = last?.notices.first { $0.hasPrefix(VMNotices.runnerEnded) }
        #expect(notice?.contains("Fatal error: Index out of range") == true, "\(last?.notices ?? [])")
        #expect(notice?.contains("maipa-g-runner-exit 132") == true)
    }
}

/// Owner, 12 November 2026: "aren't you able to fix commands if a command doesn't work… do it another way".
@Suite("Finding another way when a tool fails")
struct AnotherWayTests {
    struct AlwaysFails: AgentTool {
        let name = "sync_staged_to_computer"
        var spec: ToolSpec { ToolSpec(name: name, description: "x", parameters: ["type": "object", "properties": [:]]) }
        func runningSummary(for arguments: JSONValue) -> String { "Syncing…" }
        func run(arguments: JSONValue, progress: @escaping @Sendable (String) -> Void) async throws -> ToolOutput {
            throw ToolInputError("Argument list too long")
        }
    }

    @Test("The prompt says to get the same result another way, by hand if an app tool is broken")
    func promptSaysFindAnotherWay() {
        let prompt = SystemPrompt.make(userLogin: nil, repo: nil)
        #expect(prompt.contains("get the same result another way"))
        #expect(prompt.contains("do its job by hand with commands"))
    }

    @Test("The second identical failure tells the AI to find another way, and a third identical try isn't run")
    func secondFailureNudgesAndThirdIsBlocked() async throws {
        func attempt(_ id: String) -> ScriptedTransport.Reply {
            .events([AgentLoopTests.toolCall(id: id, name: "sync_staged_to_computer", arguments: "{}"), AgentLoopTests.toolsDone])
        }
        let transport = ScriptedTransport([attempt("c1"), attempt("c2"), attempt("c3"), .events([AgentLoopTests.text("Done another way."), AgentLoopTests.done])])
        let (turn, _) = await AgentLoopTests.runToEnd(transport, chat: AgentLoopTests.newChat("sync it"), route: AgentLoopTests.route(), tools: [AlwaysFails()])
        let calls = turn?.steps.flatMap(\.toolCalls) ?? []
        #expect(calls.count == 3)
        #expect(calls.first?.result?.contains("[MAIPA-G]") == false)
        #expect(calls.dropFirst().first?.result?.contains("get the same result another way") == true)
        #expect(calls.last?.summary == "Stopped a repeated failing tool call")
        #expect(turn?.status == .done)
    }
}

extension GatewayVideoTests {
    /// OneProvider exactly as its video guide describes it (12 November 2026).
    final class DocumentedOneProvider: HTTPTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var _bodies: [JSONValue] = []
        private var _polls = 0
        var bodies: [JSONValue] { lock.withLock { _bodies } }

        func send(_ request: HTTPRequest) async throws -> HTTPResponse {
            let url = request.url.absoluteString
            guard request.headers["Authorization"] == "Bearer sk-one" else { return HTTPResponse(status: 401, headers: [:], body: Data()) }
            if url == "https://api.oneprovider.dev/v1/videos/generations", request.method == "POST" {
                let body = request.body.flatMap { JSONValue.parse($0) } ?? .null
                lock.withLock { _bodies.append(body) }
                let ok = [5, 10].contains(body["duration"]?.intValue ?? 0) && ["16:9", "9:16"].contains(body["aspect_ratio"]?.stringValue ?? "16:9")
                    && ["720p", "1080p"].contains(body["resolution"]?.stringValue ?? "720p")
                return ok
                    ? HTTPResponse(status: 200, headers: [:], body: Data(#"{"request_id":"task_abc"}"#.utf8))
                    : HTTPResponse(status: 400, headers: [:], body: Data(#"{"error":{"message":"This combination of model, duration, resolution and options is not available"}}"#.utf8))
            }
            if url == "https://api.oneprovider.dev/v1/videos/generations/task_abc" {
                let polls = lock.withLock { _polls += 1; return _polls }
                return polls < 2
                    ? HTTPResponse(status: 200, headers: [:], body: Data(#"{"request_id":"task_abc","status":"pending","progress":50}"#.utf8))
                    : HTTPResponse(status: 200, headers: [:], body: Data(#"{"request_id":"task_abc","status":"done","progress":100,"video":{"url":"/v1/videos/generations/task_abc/content","duration":5}}"#.utf8))
            }
            if url == "https://api.oneprovider.dev/v1/videos/generations/task_abc/content" {
                return HTTPResponse(status: 200, headers: ["content-type": "video/mp4"], body: Data("documented-mp4".utf8))
            }
            return HTTPResponse(status: 404, headers: [:], body: Data())
        }
        func stream(_ request: HTTPRequest) async throws -> HTTPStreamResponse {
            HTTPStreamResponse(status: 500, headers: [:], body: AsyncThrowingStream { $0.finish() })
        }
    }

    @Test("OneProvider's documented flow: request_id, pending, done with a path on its own host, then the file")
    func documentedOneProviderFlow() async throws {
        let gateway = DocumentedOneProvider()
        // A square 8-second ask becomes what OneProvider takes (16:9, 10 s, 720p) instead of a 400.
        let video = try await AIProviderGateway.generateVideo(prompt: "blobs merge", rawModelID: "kling-3.0", duration: 8, aspectRatio: "1:1", firstFrame: nil, endpoint: Self.oneProvider, transport: gateway, pollEvery: 0.01)
        #expect(video.data == Data("documented-mp4".utf8))
        let sent = try #require(gateway.bodies.first)
        #expect(sent["duration"]?.intValue == 10)
        #expect(sent["aspect_ratio"]?.stringValue == "16:9")
        #expect(sent["resolution"]?.stringValue == "720p")
        #expect(sent["seconds"] == nil && sent["size"] == nil)
    }

    @Test("A video already started is collected by its job id, without starting (and paying for) a new one")
    func collectsAStartedVideo() async throws {
        let gateway = DocumentedOneProvider()
        let video = try await AIProviderGateway.generateVideo(prompt: "", rawModelID: "kling-3.0", duration: nil, aspectRatio: nil, firstFrame: nil, resumeJob: "task_abc", endpoint: Self.oneProvider, transport: gateway, pollEvery: 0.01)
        #expect(video.data == Data("documented-mp4".utf8))
        #expect(gateway.bodies.isEmpty)
        #expect(AIProviderGateway.videoModels(for: Self.oneProvider).first?.aspectRatios == ["16:9", "9:16"])
    }
}
