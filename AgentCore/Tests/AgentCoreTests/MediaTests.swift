import Foundation
import Testing
@testable import AgentCore

/// Owner, 11 November 2026: pictures are made and changed in the chat, the AI "picks the best for
/// whatever the situation calls for" (an edit, a new picture, or the model the person names), and
/// it can say which models there are. Plus videos.
@Suite("Pictures and videos")
struct MediaTests {
    static func model(_ id: String, input: [String] = ["text"], output: [String] = ["image"], free: Bool = false) -> ModelInfo {
        ModelInfo(id: id, name: id, promptPrice: free ? 0 : 0.000001, completionPrice: free ? 0 : 0.00001, inputModalities: input, outputModalities: output)
    }

    static let pool: [ModelInfo] = [
        model("black-forest-labs/flux-2-pro"),
        model("google/gemini-3-pro-image", input: ["text", "image"], output: ["image", "text"]),
        model("openai/gpt-image-2", input: ["text", "image"]),
        model("anthropic/claude-sonnet-5.5", input: ["text", "image"], output: ["text"]),
        model("bytedance/seedream-5", input: ["text", "image"]),
    ]

    @Test("An edit goes to a model that edits well; a new picture to the best general one")
    func picksForTheJob() {
        #expect(ImageModelChooser.best(for: .edit, among: Self.pool)?.id == "google/gemini-3-pro-image")
        #expect(ImageModelChooser.best(for: .new, among: Self.pool)?.id == "openai/gpt-image-2")
        // Never a model that can't make pictures, and an edit never a words-only model when one takes pictures.
        let wordsOnly = [Self.model("black-forest-labs/flux-2-pro"), Self.model("someone/painter", input: ["text", "image"])]
        #expect(ImageModelChooser.best(for: .edit, among: wordsOnly)?.id == "someone/painter")
        #expect(ImageModelChooser.best(for: .new, among: [Self.model("x/chat", output: ["text"])]) == nil)
    }

    @Test("The model the person names is found by id, name or a loose spelling")
    func findsNamedModels() {
        #expect(ImageModelChooser.named("openai/gpt-image-2", among: Self.pool)?.id == "openai/gpt-image-2")
        #expect(ImageModelChooser.named("Seedream 5", among: Self.pool)?.id == "bytedance/seedream-5")
        #expect(ImageModelChooser.named("flux 2 pro", among: Self.pool)?.id == "black-forest-labs/flux-2-pro")
        #expect(ImageModelChooser.named("midjourney", among: Self.pool) == nil)
    }

    @Test("The picture tool uses the named model, else the best for the job; an unknown name is explained")
    func pictureToolResolvesItsModel() throws {
        let store = AttachmentStore(dataDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("maipa-g-media-\(UUID().uuidString)"))
        let picture = AttachmentReference(name: "Photo.png", mimeType: "image/png", kind: .image, path: "attachments/x/Photo.png", bytes: 10)
        let tool = GenerateImageTool(client: OpenRouterClient(transport: URLSessionTransport(), apiKey: "key"), store: store, model: "black-forest-labs/flux-2-pro", maySpend: true, availableImages: [picture], candidates: Self.pool, chooseAutomatically: true)
        #expect(try tool.resolvedModel(["prompt": "a cat"]).id == "openai/gpt-image-2")
        #expect(try tool.resolvedModel(["prompt": "make it black", "reference_images": ["Photo.png"]]).id == "google/gemini-3-pro-image")
        #expect(try tool.resolvedModel(["prompt": "a cat", "model": "seedream"]).id == "bytedance/seedream-5")
        #expect(throws: ToolInputError.self) { try tool.resolvedModel(["prompt": "a cat", "model": "midjourney"]) }
        #expect(tool.spec.function.parameters["properties"]?["model"] != nil)
        // A picture model picked for the chat is kept.
        let picked = GenerateImageTool(client: OpenRouterClient(transport: URLSessionTransport(), apiKey: "key"), store: store, model: "black-forest-labs/flux-2-pro", maySpend: true, candidates: Self.pool, chooseAutomatically: false)
        #expect(try picked.resolvedModel(["prompt": "a cat"]).id == "black-forest-labs/flux-2-pro")
    }

    @Test("Asking for or about a picture or video keeps the reply where the picture tools are")
    func mediaRequestsAreRecognised() {
        #expect(MediaRequest.wanted("Make me a logo for my app", hasImageAttachments: false))
        #expect(MediaRequest.wanted("turn it into a video", hasImageAttachments: false))
        #expect(MediaRequest.wanted("I want the white to be black and the black to be white.", hasImageAttachments: true))
        #expect(MediaRequest.wanted("make it bluer", hasImageAttachments: false, chatHasPictures: true))
        #expect(!MediaRequest.wanted("make it bluer", hasImageAttachments: false, chatHasPictures: false))
        #expect(!MediaRequest.wanted("Fix the crash in the settings screen when the switch is off", hasImageAttachments: false))
    }

    @Test("A picture's cost is counted once, not on the picture and again on its tool call")
    func pictureCostsCountOnce() {
        var step = AssistantStep()
        let reference = AttachmentReference(name: "p.png", mimeType: "image/png", kind: .image, path: "media/x/p.png", bytes: 1)
        step.generatedImages = [GeneratedImageResult(attachment: reference, prompt: "x", model: "m", aspectRatio: "1:1", quality: "standard", cost: 0.04)]
        var picture = ToolCallRecord(id: "a", name: "generate_image", arguments: "{}", summary: "Generated", status: .done)
        picture.billedCost = 0.04
        var computer = ToolCallRecord(id: "b", name: "run_command", arguments: "{}", summary: "Ran", status: .done)
        computer.billedCost = 0.01
        step.toolCalls = [picture, computer]
        #expect(abs(AssistantStep.extraCosts([step]).reduce(0, +) - 0.05) < 0.000001)
    }

    final class VideoTransport: HTTPTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var polls = 0
        private(set) var submitted: JSONValue?
        func send(_ request: HTTPRequest) async throws -> HTTPResponse {
            lock.withLock { answer(request) }
        }
        private func answer(_ request: HTTPRequest) -> HTTPResponse {
            let path = request.url.path
            if path.hasSuffix("/videos/models") {
                return HTTPResponse(status: 200, headers: [:], body: Data(#"{"data":[{"id":"google/veo-3.1","name":"Veo 3.1","supported_durations":[4,6,8],"supported_resolutions":["720p","1080p"],"pricing_skus":{"per-video-second":"0.50","per-video-second-1080p":"0.75"}},{"id":"alibaba/wan-2.7","name":"Wan 2.7","pricing_skus":{"per-video-second":"0.10"}}]}"#.utf8))
            }
            if request.method == "POST", path.hasSuffix("/videos") {
                submitted = request.body.flatMap(JSONValue.parse)
                return HTTPResponse(status: 202, headers: [:], body: Data(#"{"id":"job1","polling_url":"https://openrouter.ai/api/v1/videos/job1","status":"pending"}"#.utf8))
            }
            if path.hasSuffix("/videos/job1") {
                polls += 1
                let status = polls >= 2 ? "completed" : "in_progress"
                return HTTPResponse(status: 200, headers: [:], body: Data(#"{"id":"job1","status":"\#(status)","unsigned_urls":["https://openrouter.ai/api/v1/videos/job1/content?index=0"],"usage":{"cost":2.5}}"#.utf8))
            }
            if path.hasSuffix("/videos/job1/content") {
                return HTTPResponse(status: 200, headers: ["content-type": "video/mp4"], body: Data("fake-mp4".utf8))
            }
            return HTTPResponse(status: 404, headers: [:], body: Data())
        }
        func stream(_ request: HTTPRequest) async throws -> HTTPStreamResponse {
            HTTPStreamResponse(status: 500, headers: [:], body: AsyncThrowingStream { $0.finish() })
        }
    }

    @Test("A video is started, waited on and downloaded, from a chat picture as its first frame")
    func makesAVideo() async throws {
        let transport = VideoTransport()
        let client = OpenRouterClient(transport: transport, apiKey: "key")
        let models = try await client.videoModels()
        #expect(models.map(\.id) == ["google/veo-3.1", "alibaba/wan-2.7"])
        #expect(models.first?.pricePerSecond == 0.5)
        #expect(VideoModelInfo.best(among: models, fromPicture: true)?.id == "google/veo-3.1")
        let frame = ImageInput(name: "p.png", mimeType: "image/png", data: Data([1, 2, 3]))
        let video = try await client.generateVideo(prompt: "the face blinks", model: "google/veo-3.1", duration: 4, resolution: "720p", aspectRatio: "16:9", firstFrame: frame, pollEvery: 0.01)
        #expect(video.data == Data("fake-mp4".utf8))
        #expect(video.mimeType == "video/mp4")
        #expect(video.cost == 2.5)
        #expect(transport.submitted?["frame_images"]?.arrayValue?.first?["frame_type"]?.stringValue == "first_frame")
        #expect(transport.submitted?["duration"]?.intValue == 4)
        #expect(GenerateVideoTool.seconds(["duration_seconds": 5], model: models[0]) == 4 || GenerateVideoTool.seconds(["duration_seconds": 5], model: models[0]) == 6)
    }

    @Test("A file comes back from the computer whole, in smaller pieces when the service cuts output short", .enabled(if: ComputerTransferTests.onLinux))
    func readsFilesBack() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("maipa-g-read-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent("pictures"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        var bytes = Data(count: 150_000)
        for index in bytes.indices { bytes[index] = UInt8.random(in: 0...255) }
        try bytes.write(to: home.appendingPathComponent("pictures/out.png"))
        let local = ComputerControl.local(machine: "test", home: home)
        // A service that never prints more than 100 KB from one command.
        let capped = ComputerControl(tools: local.tools, machine: "test") { name, arguments in
            let result = try await local.call(name, arguments)
            return (String(result.text.prefix(100_000)), result.isError)
        }
        #expect(try await capped.readFile(homePath: "pictures/out.png") == bytes)
        await #expect(throws: (any Error).self) { try await capped.readFile(homePath: "pictures/missing.png") }
    }
}
