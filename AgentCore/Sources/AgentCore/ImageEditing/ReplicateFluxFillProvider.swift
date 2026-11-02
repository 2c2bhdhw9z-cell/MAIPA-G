import Foundation

/// Replicate adapter for the pinned FLUX.1 Fill [pro] version documented in
/// `docs/IMAGE-EDITING-PROVIDER.md`. It performs no request until `edit` is called. The iOS app
/// must call it only after its paid-operation approval and must keep the token in Keychain.
public struct ReplicateFluxFillProvider: ImageEditProvider {
    public static let providerName = "Replicate"
    public static let modelName = "black-forest-labs/flux-fill-pro"
    public static let pinnedVersion = "b23335a86ed317e5a35eb1be11bbf8f8985f9fdf12c53484ecf930d734095f74"
    public static let maximumDataURLFileBytes = 900_000
    private static let maximumPollCount = 90
    private static let maximumOutputBytes = 32 * 1_024 * 1_024
    private static let apiBase = URL(string: "https://api.replicate.com/v1")!

    private let token: String
    private let transport: any HTTPTransport

    public var capabilities: ImageEditCapabilities {
        ImageEditCapabilities(
            provider: Self.providerName,
            model: Self.modelName,
            modelVersion: Self.pinnedVersion,
            canEditSourceImage: true,
            acceptsMask: true,
            acceptsSeed: true,
            acceptedMimeTypes: ["image/jpeg", "image/png", "image/webp"],
            maximumInputBytes: Self.maximumDataURLFileBytes,
            maximumOutputBytes: Self.maximumOutputBytes
        )
    }

    public init(token: String, transport: any HTTPTransport) throws {
        let clean = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.utf8.count <= 512,
              clean.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
            throw ImageEditProviderError.invalidInput("A valid Replicate API token is required in this device's Keychain.")
        }
        self.token = clean
        self.transport = transport
    }

    public func edit(_ request: ImageEditRequest) async throws -> ImageEditResponse {
        try request.validate(for: capabilities)
        guard request.sourceData.count <= Self.maximumDataURLFileBytes,
              request.maskData.count <= Self.maximumDataURLFileBytes else {
            throw ImageEditProviderError.inputTooLarge(maximumBytes: Self.maximumDataURLFileBytes)
        }
        let cleanPrompt = request.instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        var input: [String: JSONValue] = [
            "prompt": .string(cleanPrompt),
            "image": .string(Self.dataURL(mimeType: request.sourceMimeType, bytes: request.sourceData)),
            "mask": .string(Self.dataURL(mimeType: request.maskMimeType, bytes: request.maskData)),
            "output_format": .string("jpg"),
            "prompt_upsampling": .bool(false)
        ]
        if let seed = request.seed {
            guard seed >= 0, seed <= 9_007_199_254_740_991 else {
                throw ImageEditProviderError.invalidInput("Seed must be a non-negative integer.")
            }
            input["seed"] = .number(Double(seed))
        }
        let createBody: JSONValue = .object([
            "version": .string(Self.pinnedVersion),
            "input": .object(input)
        ])
        var createRequest = try HTTPRequest.json(
            "POST",
            Self.apiBase.appendingPathComponent("predictions"),
            body: createBody,
            headers: ["Authorization": "Bearer \(token)", "Prefer": "wait=10", "Cancel-After": "2m"],
            idleTimeout: 30
        )
        createRequest.followsRedirects = false
        var prediction = try await sendPrediction(createRequest)
        if !prediction.isTerminal {
            do {
                prediction = try await poll(prediction)
            } catch is CancellationError {
                await cancelPrediction(prediction)
                throw CancellationError()
            }
        }
        guard prediction.status == "succeeded" || prediction.status == "successful" else {
            let safeStatus = prediction.status.isEmpty ? "unknown" : prediction.status
            throw ImageEditProviderError.provider("The image-edit request ended with status \(safeStatus). No usable picture was returned.")
        }
        guard let output = prediction.firstOutputURL,
              Self.isExpectedOutputURL(output) else {
            throw ImageEditProviderError.invalidResponse("The provider did not return a safe image file URL.")
        }
        let (data, mimeType) = try await downloadOutput(output)
        let response = ImageEditResponse(
            imageData: data,
            mimeType: mimeType,
            provider: Self.providerName,
            model: Self.modelName,
            modelVersion: Self.pinnedVersion,
            seed: prediction.returnedSeed,
            cost: nil
        )
        try response.validate(maximumOutputBytes: Self.maximumOutputBytes)
        return response
    }

    private func sendPrediction(_ request: HTTPRequest) async throws -> Prediction {
        let response = try await transport.send(request)
        guard response.finalURL.map(Self.isAPIURL) ?? true else {
            throw ImageEditProviderError.invalidResponse("The provider redirected the credential-bearing request to an unexpected host.")
        }
        guard response.isSuccess else {
            throw ImageEditProviderError.provider("Replicate returned HTTP \(response.status) while starting or checking the edit.")
        }
        do {
            return try response.decode(Prediction.self)
        } catch {
            throw ImageEditProviderError.invalidResponse("Replicate returned an unreadable prediction response.")
        }
    }

    private func poll(_ initial: Prediction) async throws -> Prediction {
        guard let url = initial.getURL, Self.isPredictionURL(url) else {
            throw ImageEditProviderError.invalidResponse("Replicate returned an unsafe prediction polling URL.")
        }
        var latest = initial
        for _ in 0..<Self.maximumPollCount {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 1_000_000_000)
            let request = HTTPRequest(method: "GET", url: url, headers: ["Authorization": "Bearer \(token)"], idleTimeout: 30, followsRedirects: false)
            latest = try await sendPrediction(request)
            if latest.isTerminal { return latest }
        }
        await cancelPrediction(latest)
        throw ImageEditProviderError.provider("The image-edit request took too long and was canceled. Try again later.")
    }

    private func cancelPrediction(_ prediction: Prediction) async {
        guard let id = prediction.id, Self.safePredictionID(id) else { return }
        let url = Self.apiBase.appendingPathComponent("predictions").appendingPathComponent(id).appendingPathComponent("cancel")
        let request = HTTPRequest(method: "POST", url: url, headers: ["Authorization": "Bearer \(token)"], idleTimeout: 10, followsRedirects: false)
        _ = try? await transport.send(request)
    }

    private func downloadOutput(_ url: URL) async throws -> (Data, String) {
        let request = HTTPRequest(method: "GET", url: url, idleTimeout: 60, followsRedirects: false)
        let response = try await transport.stream(request)
        guard (200..<300).contains(response.status) else {
            throw ImageEditProviderError.provider("The completed edit could not be downloaded (HTTP \(response.status)).")
        }
        if let contentLength = response.header("content-length").flatMap(Int.init), contentLength > Self.maximumOutputBytes {
            throw ImageEditProviderError.invalidResponse("The edited picture exceeded the safe output-size limit.")
        }
        let mimeType = response.header("content-type")?.split(separator: ";", maxSplits: 1).first.map(String.init)?.lowercased() ?? ""
        guard ["image/jpeg", "image/png", "image/webp"].contains(mimeType) else {
            throw ImageEditProviderError.invalidResponse("The provider returned a non-image or unsupported file type.")
        }
        var data = Data()
        do {
            for try await chunk in response.body {
                data.append(chunk)
                if data.count > Self.maximumOutputBytes {
                    throw ImageEditProviderError.invalidResponse("The edited picture exceeded the safe output-size limit.")
                }
            }
        } catch let error as ImageEditProviderError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ImageEditProviderError.provider("The edited picture download was interrupted.")
        }
        return (data, mimeType)
    }

    private static func dataURL(mimeType: String, bytes: Data) -> String {
        "data:\(mimeType);base64,\(bytes.base64EncodedString())"
    }

    private static func isAPIURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https"
            && url.host?.lowercased() == "api.replicate.com"
            && (url.port == nil || url.port == 443)
            && url.user == nil && url.password == nil
    }

    private static func isPredictionURL(_ url: URL) -> Bool {
        guard isAPIURL(url), url.query == nil, url.fragment == nil else { return false }
        let components = url.pathComponents
        return components.count == 4 && components[1] == "v1" && components[2] == "predictions" && safePredictionID(components[3])
    }

    private static func isExpectedOutputURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased(),
              (url.port == nil || url.port == 443), url.user == nil, url.password == nil, url.fragment == nil else { return false }
        return host == "replicate.delivery" || host.hasSuffix(".replicate.delivery")
    }

    private static func safePredictionID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 128 && id.utf8.allSatisfy { byte in
            (byte >= 48 && byte <= 57) || (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122) || byte == 45
        }
    }

    private struct Prediction: Decodable, Sendable {
        var id: String?
        var status: String
        var output: JSONValue?
        var error: JSONValue?
        var urls: [String: String]?
        var seed: Int64?

        var isTerminal: Bool { ["succeeded", "successful", "failed", "canceled", "cancelled"].contains(status) }
        var getURL: URL? { urls?["get"].flatMap(URL.init(string:)) }
        var returnedSeed: Int64? { seed }
        var firstOutputURL: URL? {
            if let value = output?.stringValue { return URL(string: value) }
            if let value = output?.arrayValue?.first?.stringValue { return URL(string: value) }
            return nil
        }
    }
}
