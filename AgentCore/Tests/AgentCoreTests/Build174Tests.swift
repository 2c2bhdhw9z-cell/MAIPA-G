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
