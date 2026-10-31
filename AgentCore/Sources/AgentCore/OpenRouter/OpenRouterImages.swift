import Foundation

public enum ImageAspectRatio: String, Codable, Sendable, Hashable, CaseIterable { case square = "1:1", portrait = "3:4", landscape = "4:3", wide = "16:9", tall = "9:16" }
public enum ImageQuality: String, Codable, Sendable, Hashable, CaseIterable { case standard, high }

public struct ImageGenerationOptions: Codable, Sendable, Hashable {
    public var aspectRatio: ImageAspectRatio
    public var quality: ImageQuality
    public var count: Int
    public init(aspectRatio: ImageAspectRatio = .square, quality: ImageQuality = .standard, count: Int = 1) {
        self.aspectRatio = aspectRatio; self.quality = quality; self.count = min(max(count, 1), 4)
    }
}

public struct GeneratedImage: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var prompt: String
    public var model: String
    public var mimeType: String
    public var data: Data
    public var revisedPrompt: String?
    public var cost: Double?
    public var options: ImageGenerationOptions
    public var createdAt: Date
    public init(id: UUID = UUID(), prompt: String, model: String, mimeType: String = "image/png", data: Data, revisedPrompt: String? = nil, cost: Double? = nil, options: ImageGenerationOptions, createdAt: Date = Date()) {
        self.id = id; self.prompt = prompt; self.model = model; self.mimeType = mimeType; self.data = data
        self.revisedPrompt = revisedPrompt; self.cost = cost; self.options = options; self.createdAt = createdAt
    }
}

public extension ModelInfo {
    /// True for dedicated image generators (`['image']`) and multimodal image-writing models (`['image','text']`),
    /// never for `openrouter/auto*` meta-routers.
    var generatesImages: Bool { !isRouter && outputModalities.contains("image") && !id.hasSuffix(":batch") }

    /// Pure image-only models (`output_modalities == ["image"]`) use `/api/v1/images` and cannot write text replies.
    var isPureImageModel: Bool { generatesImages && !outputModalities.contains("text") }
}

public extension OpenRouterClient {
    /// Generates actual image bytes through OpenRouter's `/api/v1/images` endpoint (for pure image models like
    /// FLUX, Seedream, Qwen Image, Recraft, Riverflow, Krea) or `/api/v1/chat/completions` with
    /// `modalities: ["image", "text"]` (for multimodal chat-image models like Gemini Flash Image and GPT-5 Image).
    func generateImages(
        prompt: String,
        model: String,
        options: ImageGenerationOptions = .init(),
        progress: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> [GeneratedImage] {
        let clean = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw ToolInputError("An image prompt is required.") }
        progress("Generating picture…")
        if let routed = providerEndpoint(for: model) {
            let images = try await AIProviderGateway.generateImages(
                prompt: clean,
                rawModelID: routed.rawModelID,
                options: options,
                endpoint: routed.endpoint,
                transport: transport
            )
            progress("Picture ready")
            return images
        }

        let catalogEntry = catalogueByID[model]
        let lowerModel = model.lowercased()
        let prefersChatImagesEndpoint = (catalogEntry?.isChatModel == true && catalogEntry?.generatesImages == true)
            || lowerModel.contains("gemini-") && lowerModel.contains("image")
            || lowerModel.contains("gpt-5-image")

        if prefersChatImagesEndpoint {
            return try await generateImagesViaChatCompletions(prompt: clean, model: model, options: options, progress: progress)
        }

        let body: JSONValue = [
            "model": .string(model),
            "prompt": .string(clean),
            "n": .number(Double(options.count)),
            "aspect_ratio": .string(options.aspectRatio.rawValue),
            "quality": .string(options.quality.rawValue),
            "response_format": "b64_json",
        ]
        let request = try HTTPRequest.json("POST", Self.apiBase.appendingPathComponent("images"), body: body, headers: headers(forModel: model), idleTimeout: 300)
        let response = try await transport.send(request)
        if !response.isSuccess,
           (response.status == 400 || response.status == 404 || response.status == 405),
           catalogEntry?.outputModalities.contains("text") == true {
            return try await generateImagesViaChatCompletions(prompt: clean, model: model, options: options, progress: progress)
        }
        guard response.isSuccess else { throw OpenRouterAPIError(status: response.status, body: response.body, headers: response.headers) }
        guard let root = JSONValue.parse(response.body), let values = root["data"]?.arrayValue else {
            throw HTTPError.undecodable(status: response.status, type: "generated image", detail: "missing data", body: response.text)
        }
        let cost = root["usage"]?["cost"]?.doubleValue ?? root["cost"]?.doubleValue
        var images: [GeneratedImage] = []
        for value in values {
            let mime = value["media_type"]?.stringValue ?? value["mime_type"]?.stringValue ?? "image/png"
            let bytes: Data?
            if let encoded = value["b64_json"]?.stringValue {
                bytes = Self.decodeImagePayload(encoded).data
            } else if let text = value["url"]?.stringValue {
                if text.hasPrefix("data:") {
                    bytes = Self.decodeImagePayload(text).data
                } else if let url = URL(string: text) {
                    progress("Saving picture…")
                    let downloaded = try await transport.send(HTTPRequest(url: url, idleTimeout: 120))
                    guard downloaded.isSuccess else { throw HTTPError.status(code: downloaded.status, body: downloaded.text, headers: downloaded.headers) }
                    bytes = downloaded.body
                } else {
                    bytes = nil
                }
            } else {
                bytes = nil
            }
            guard let bytes, !bytes.isEmpty else { continue }
            images.append(
                GeneratedImage(
                    prompt: clean,
                    model: model,
                    mimeType: mime,
                    data: bytes,
                    revisedPrompt: value["revised_prompt"]?.stringValue,
                    cost: cost.map { $0 / Double(max(values.count, 1)) },
                    options: options
                )
            )
        }
        guard !images.isEmpty else {
            throw HTTPError.undecodable(status: response.status, type: "generated image", detail: "no image bytes", body: response.text)
        }
        progress("Picture ready")
        return images
    }

    private func generateImagesViaChatCompletions(
        prompt: String,
        model: String,
        options: ImageGenerationOptions,
        progress: @escaping @Sendable (String) -> Void
    ) async throws -> [GeneratedImage] {
        let body: JSONValue = [
            "model": .string(model),
            "stream": .bool(false),
            "modalities": ["image", "text"],
            "image_config": ["aspect_ratio": .string(options.aspectRatio.rawValue)],
            "messages": [
                ["role": "user", "content": .string(prompt)],
            ],
        ]
        let req = try HTTPRequest.json("POST", Self.apiBase.appendingPathComponent("chat/completions"), body: body, headers: headers(forModel: model), idleTimeout: 300)
        let response = try await transport.send(req)
        guard response.isSuccess else {
            throw OpenRouterAPIError(status: response.status, body: response.body, headers: response.headers)
        }
        guard let root = JSONValue.parse(response.body) else {
            throw HTTPError.undecodable(status: response.status, type: "generated image", detail: "invalid JSON", body: response.text)
        }
        let message = root["choices"]?.arrayValue?.first?["message"]
        let rawImages = message?["images"]?.arrayValue ?? []
        let caption = message?["content"]?.stringValue
        let cost = root["usage"]?["cost"]?.doubleValue ?? root["cost"]?.doubleValue
        var out: [GeneratedImage] = []
        for entry in rawImages {
            guard let rawURL = entry["image_url"]?["url"]?.stringValue ?? entry["url"]?.stringValue else { continue }
            if rawURL.hasPrefix("data:") {
                let decoded = Self.decodeImagePayload(rawURL)
                if let bytes = decoded.data, !bytes.isEmpty {
                    out.append(
                        GeneratedImage(
                            prompt: prompt,
                            model: model,
                            mimeType: decoded.mimeType ?? "image/png",
                            data: bytes,
                            revisedPrompt: caption,
                            cost: cost.map { $0 / Double(max(rawImages.count, 1)) },
                            options: options
                        )
                    )
                }
            } else if let remote = URL(string: rawURL) {
                progress("Saving picture…")
                let dl = try await transport.send(HTTPRequest(url: remote, idleTimeout: 120))
                if dl.isSuccess, !dl.body.isEmpty {
                    out.append(
                        GeneratedImage(
                            prompt: prompt,
                            model: model,
                            mimeType: dl.headers["content-type"] ?? "image/png",
                            data: dl.body,
                            revisedPrompt: caption,
                            cost: cost.map { $0 / Double(max(rawImages.count, 1)) },
                            options: options
                        )
                    )
                }
            }
        }
        guard !out.isEmpty else {
            throw HTTPError.undecodable(status: response.status, type: "generated image", detail: "no image returned in message.images", body: response.text)
        }
        progress("Picture ready")
        return out
    }

    static func decodeImagePayload(_ raw: String) -> (mimeType: String?, data: Data?) {
        if raw.hasPrefix("data:"), let comma = raw.firstIndex(of: ",") {
            let header = String(raw[raw.index(raw.startIndex, offsetBy: 5)..<comma])
            let mime = header.split(separator: ";").first.map(String.init)
            let b64 = String(raw[raw.index(after: comma)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            return (mime, Data(base64Encoded: b64))
        }
        return (nil, Data(base64Encoded: raw.trimmingCharacters(in: .whitespacesAndNewlines)))
    }
}

public struct GenerateImageTool: AgentTool {
    public let client: OpenRouterClient
    public let store: AttachmentStore
    public let model: String
    public let maySpend: Bool
    public let name = "generate_image"
    public init(client: OpenRouterClient, store: AttachmentStore, model: String, maySpend: Bool) { self.client = client; self.store = store; self.model = model; self.maySpend = maySpend }
    public var spec: ToolSpec { ToolSpec(name: name, description: "Generate and save a real picture.", parameters: ["type": "object", "properties": ["prompt": ["type": "string"], "aspect_ratio": ["type": "string", "enum": ["1:1", "3:4", "4:3", "16:9", "9:16"]], "quality": ["type": "string", "enum": ["standard", "high"]]], "required": ["prompt"]]) }
    public func runningSummary(for arguments: JSONValue) -> String { "Generating a picture…" }
    public func approvalRequest(for arguments: JSONValue) async -> ToolApprovalRequest? {
        guard maySpend else { return nil }
        let service = client.providerEndpoint(for: model)?.endpoint.name ?? "OpenRouter"
        return ToolApprovalRequest(question: "Generate this billed picture with \(service)?", allowLabel: "Generate")
    }
    public func run(arguments: JSONValue, progress: @escaping @Sendable (String) -> Void) async throws -> ToolOutput {
        let prompt = try arguments.requiredString("prompt")
        let aspect = arguments.optionalString("aspect_ratio").flatMap(ImageAspectRatio.init(rawValue:)) ?? .square
        let quality = arguments.optionalString("quality").flatMap(ImageQuality.init(rawValue:)) ?? .standard
        let generated = try await client.generateImages(prompt: prompt, model: model, options: ImageGenerationOptions(aspectRatio: aspect, quality: quality), progress: progress)
        var results: [GeneratedImageResult] = []
        for image in generated {
            let ext = image.mimeType.contains("jpeg") || image.mimeType.contains("jpg") ? "jpg" : (image.mimeType.contains("webp") ? "webp" : "png")
            let reference = try await store.importGeneratedImage(image.data, name: "picture-\(image.id.uuidString.lowercased()).\(ext)", mimeType: image.mimeType)
            let result = GeneratedImageResult(attachment: reference, prompt: image.prompt, model: image.model, aspectRatio: aspect.rawValue, quality: quality.rawValue, cost: image.cost)
            try await store.saveGeneratedMetadata(result)
            results.append(result)
        }
        let cost = results.compactMap(\.cost).reduce(0, +)
        return ToolOutput(
            forModel: "Generated \(results.count) saved picture(s) using \(model).",
            summary: results.count == 1 ? "Generated a picture" : "Generated \(results.count) pictures",
            detail: cost > 0 ? "Cost: $\(String(format: "%.4f", cost))" : nil,
            generatedImages: results,
            billedCost: cost
        )
    }
}
