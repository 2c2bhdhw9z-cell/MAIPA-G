import Foundation
import Testing
@testable import AgentCore

private final class ReplicateFixtureTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var captured: [HTTPRequest] = []
    private let predictionBody: Data
    private let outputBytes: Data
    private let outputMime: String
    private let createStatus: Int

    init(
        prediction: [String: JSONValue],
        outputBytes: Data = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
        outputMime: String = "image/png",
        createStatus: Int = 201
    ) throws {
        predictionBody = try JSONCoding.encoder().encode(JSONValue.object(prediction))
        self.outputBytes = outputBytes
        self.outputMime = outputMime
        self.createStatus = createStatus
    }

    var requests: [HTTPRequest] {
        lock.lock(); defer { lock.unlock() }
        return captured
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        lock.withLock { captured.append(request) }
        if request.method == "POST" && request.url.path == "/v1/predictions" {
            return HTTPResponse(status: createStatus, headers: ["content-type": "application/json"], body: predictionBody, finalURL: request.url)
        }
        return HTTPResponse(status: 404, body: Data(), finalURL: request.url)
    }

    func stream(_ request: HTTPRequest) async throws -> HTTPStreamResponse {
        lock.withLock { captured.append(request) }
        let stream = AsyncThrowingStream<Data, Error> { continuation in
            continuation.yield(outputBytes)
            continuation.finish()
        }
        return HTTPStreamResponse(status: 200, headers: ["content-type": outputMime, "content-length": String(outputBytes.count)], body: stream)
    }

    func upload(_ request: HTTPRequest, fromFile file: URL) async throws -> HTTPResponse {
        HTTPResponse(status: 500, finalURL: request.url)
    }
}

@Suite("Pinned Replicate FLUX Fill adapter (fixture transport only; no billable call)")
struct ReplicateFluxFillProviderTests {
    private func sourceRequest(seed: Int64? = 17) -> ImageEditRequest {
        ImageEditRequest(
            sourceData: Data([1, 2, 3]), sourceMimeType: "image/png", sourcePixelWidth: 2, sourcePixelHeight: 2,
            maskData: Data([255, 0, 0, 0]), maskMimeType: "image/png", maskPixelWidth: 2, maskPixelHeight: 2,
            instruction: "change the painted area", seed: seed
        )
    }

    private func provider(transport: ReplicateFixtureTransport) throws -> ReplicateFluxFillProvider {
        try ReplicateFluxFillProvider(token: "r8_fixture_token_never_sent", transport: transport)
    }

    @Test("Pinned version request is exact and secret stays in the authorization header")
    func exactRequestShape() async throws {
        let get = "https://api.replicate.com/v1/predictions/abc123"
        let transport = try ReplicateFixtureTransport(prediction: [
            "id": .string("abc123"), "status": .string("succeeded"),
            "output": .string("https://replicate.delivery/files/result.png"),
            "seed": .number(17), "urls": .object(["get": .string(get)])
        ])
        let result = try await provider(transport: transport).edit(sourceRequest())
        #expect(result.imageData == Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]))
        #expect(result.mimeType == "image/png")
        #expect(result.provider == "Replicate")
        #expect(result.modelVersion == ReplicateFluxFillProvider.pinnedVersion)
        #expect(result.seed == 17)
        #expect(result.cost == nil)

        let requests = transport.requests
        #expect(requests.count == 2)
        let create = try #require(requests.first)
        #expect(create.method == "POST")
        #expect(create.url.absoluteString == "https://api.replicate.com/v1/predictions")
        #expect(create.followsRedirects == false)
        #expect(create.headers["Authorization"] == "Bearer r8_fixture_token_never_sent")
        let bodyData = try #require(create.body)
        let body = try JSONCoding.decoder().decode(JSONValue.self, from: bodyData)
        #expect(body["version"]?.stringValue == ReplicateFluxFillProvider.pinnedVersion)
        #expect(body["input"]?["prompt"]?.stringValue == "change the painted area")
        #expect(body["input"]?["seed"]?.intValue == 17)
        #expect(body["input"]?["output_format"]?.stringValue == "jpg")
        #expect(body["input"]?["prompt_upsampling"]?.boolValue == false)
        #expect(body["input"]?["image"]?.stringValue == "data:image/png;base64,AQID")
        #expect(body["input"]?["mask"]?.stringValue == "data:image/png;base64,/wAAAA==")
        #expect(!String(decoding: bodyData, as: UTF8.self).contains("r8_fixture_token_never_sent"))

        let outputRequest = try #require(requests.last)
        #expect(outputRequest.url.host == "replicate.delivery")
        #expect(outputRequest.method == "GET")
        #expect(outputRequest.followsRedirects == false)
        #expect(outputRequest.headers["Authorization"] == nil)
    }

    @Test("Unsupported mask dimensions fail before creating a prediction")
    func noRequestOnInvalidMask() async throws {
        let transport = try ReplicateFixtureTransport(prediction: ["status": .string("succeeded")])
        do {
            _ = try await provider(transport: transport).edit(ImageEditRequest(
                sourceData: Data([1]), sourceMimeType: "image/png", sourcePixelWidth: 3, sourcePixelHeight: 2,
                maskData: Data([2]), maskMimeType: "image/png", maskPixelWidth: 2, maskPixelHeight: 2,
                instruction: "edit"
            ))
            Issue.record("Expected mismatched mask dimensions to be rejected")
        } catch is ImageEditProviderError {
            #expect(transport.requests.isEmpty)
        }
    }

    @Test("Unexpected output hosts and non-image MIME types are rejected")
    func rejectsUnsafeOutput() async throws {
        let unsafeTransport = try ReplicateFixtureTransport(prediction: [
            "id": .string("abc123"), "status": .string("succeeded"),
            "output": .string("https://attacker.example/result.png")
        ])
        do {
            _ = try await provider(transport: unsafeTransport).edit(sourceRequest())
            Issue.record("Expected an unexpected output host to be rejected")
        } catch is ImageEditProviderError {
            #expect(unsafeTransport.requests.count == 1)
        }

        let badMimeTransport = try ReplicateFixtureTransport(prediction: [
            "id": .string("abc123"), "status": .string("succeeded"),
            "output": .string("https://replicate.delivery/files/result.txt")
        ], outputMime: "text/plain")
        do {
            _ = try await provider(transport: badMimeTransport).edit(sourceRequest())
            Issue.record("Expected an unsupported output type to be rejected")
        } catch is ImageEditProviderError {
            #expect(badMimeTransport.requests.count == 2)
        }
    }

    @Test("The 900 KB data-URL bound rejects large input before any request")
    func inputBound() async throws {
        let transport = try ReplicateFixtureTransport(prediction: ["status": .string("succeeded")])
        var request = sourceRequest()
        request.sourceData = Data(repeating: 1, count: ReplicateFluxFillProvider.maximumDataURLFileBytes + 1)
        do {
            _ = try await provider(transport: transport).edit(request)
            Issue.record("Expected an oversized source image to be rejected")
        } catch is ImageEditProviderError {
            #expect(transport.requests.isEmpty)
        }
    }
}
