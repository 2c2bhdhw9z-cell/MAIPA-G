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

/// A picture sent to an image model as input (image-to-image or editing).
public struct ImageInput: Sendable, Hashable {
    public var name: String
    public var mimeType: String
    public var data: Data
    public init(name: String, mimeType: String, data: Data) {
        self.name = name; self.mimeType = mimeType; self.data = data
    }
    public var dataURL: String { "data:\(mimeType);base64,\(data.base64EncodedString())" }
    var reference: JSONValue { ["type": "image_url", "image_url": ["url": .string(dataURL)]] }
}

/// Whether a message to a picture model is about a picture already in the chat ("make it blue",
/// "edit the last picture"), so that picture goes in as input. A fresh description is not.
public enum ImageEditIntent {
    static let phrases = [
        "edit", "change", "modify", "adjust", "tweak", "fix", "retouch", "recolor", "recolour",
        "this picture", "this image", "this photo", "that picture", "that image", "that photo",
        "the picture", "the image", "the photo", "last picture", "last image", "previous",
        "make it", "same picture", "same image", "same but", "remove the", "replace the", "turn it",
    ]

    public static func refersToEarlierPicture(_ message: String) -> Bool {
        let text = " " + message.lowercased().replacingOccurrences(of: "\n", with: " ") + " "
        let words = text.map { $0.isLetter || $0.isNumber ? $0 : " " }
        let padded = " " + String(words).split(separator: " ").joined(separator: " ") + " "
        return phrases.contains { padded.contains(" \($0) ") }
    }
}

/// A model that only makes pictures from words was given a picture to work from.
public struct ImageInputNotSupported: Error, Sendable, CustomStringConvertible {
    public let modelName: String
    public init(modelName: String) { self.modelName = modelName }
    public var description: String {
        "\(modelName) can't take a picture as input: it only makes pictures from a written description. Pick a picture model that accepts images to edit or build on a picture."
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
    /// Whether `model` takes pictures as input: true or false when the catalogue says, nil when unknown.
    func acceptsImageInput(_ model: String) -> Bool? {
        guard let entry = catalogueByID[model] else { return nil }
        return entry.acceptsImages
    }

    func generateImages(
        prompt: String,
        model: String,
        options: ImageGenerationOptions = .init(),
        inputImages: [ImageInput] = [],
        progress: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> [GeneratedImage] {
        let clean = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw ToolInputError("An image prompt is required.") }
        // Never drop a picture silently: a model known not to take pictures says so instead.
        if !inputImages.isEmpty, acceptsImageInput(model) == false {
            throw ImageInputNotSupported(modelName: catalogueByID[model]?.name ?? model)
        }
        progress(inputImages.isEmpty ? "Generating picture…" : "Working from your picture…")
        if let routed = providerEndpoint(for: model) {
            let images = try await AIProviderGateway.generateImages(
                prompt: clean,
                rawModelID: routed.rawModelID,
                options: options,
                endpoint: routed.endpoint,
                transport: transport,
                inputImages: inputImages
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
            return try await generateImagesViaChatCompletions(prompt: clean, model: model, options: options, inputImages: inputImages, progress: progress)
        }

        var fields: [String: JSONValue] = [
            "model": .string(model),
            "prompt": .string(clean),
            "n": .number(Double(options.count)),
            "aspect_ratio": .string(options.aspectRatio.rawValue),
            "quality": .string(options.quality.rawValue),
            "response_format": "b64_json",
        ]
        if !inputImages.isEmpty {
            fields["input_references"] = .array(inputImages.prefix(16).map(\.reference))
        }
        let body = JSONValue.object(fields)
        let request = try HTTPRequest.json("POST", Self.apiBase.appendingPathComponent("images"), body: body, headers: headers(forModel: model), idleTimeout: 300)
        let response = try await transport.send(request)
        if !response.isSuccess,
           (response.status == 400 || response.status == 404 || response.status == 405),
           catalogEntry?.outputModalities.contains("text") == true {
            return try await generateImagesViaChatCompletions(prompt: clean, model: model, options: options, inputImages: inputImages, progress: progress)
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
        inputImages: [ImageInput] = [],
        progress: @escaping @Sendable (String) -> Void
    ) async throws -> [GeneratedImage] {
        let content: JSONValue = inputImages.isEmpty
            ? .string(prompt)
            : .array([["type": "text", "text": .string(prompt)]] + inputImages.map(\.reference))
        let body: JSONValue = [
            "model": .string(model),
            "stream": .bool(false),
            "modalities": ["image", "text"],
            "image_config": ["aspect_ratio": .string(options.aspectRatio.rawValue)],
            "messages": [
                ["role": "user", "content": content],
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
    /// Pictures in the chat (attached or generated) the model may name as input.
    public let availableImages: [AttachmentReference]
    /// Every picture model the person can use. When `chooseAutomatically` is on (they haven't
    /// picked a picture model for the chat), the model is chosen for the job: one that edits
    /// well for an edit, the best general one for a new picture, or the one the AI names.
    public let candidates: [ModelInfo]
    public let chooseAutomatically: Bool
    public let name = "generate_image"
    public init(client: OpenRouterClient, store: AttachmentStore, model: String, maySpend: Bool, availableImages: [AttachmentReference] = [], candidates: [ModelInfo] = [], chooseAutomatically: Bool = false) {
        self.client = client; self.store = store; self.model = model; self.maySpend = maySpend
        self.availableImages = availableImages.filter { $0.kind == .image && !$0.mimeType.hasPrefix("video/") }
        self.candidates = candidates.filter(\.generatesImages)
        self.chooseAutomatically = chooseAutomatically
    }

    /// The model for this call: the one named, else the chat's picked picture model, else the
    /// best for the job.
    func resolvedModel(_ arguments: JSONValue) throws -> (id: String, maySpend: Bool) {
        let isEdit = !(arguments["reference_images"]?.arrayValue ?? []).isEmpty
        if let wanted = arguments.optionalString("model"), !wanted.isEmpty, wanted.lowercased() != "auto" {
            if let match = ImageModelChooser.named(wanted, among: candidates) { return (match.id, !match.isFree) }
            if wanted == model { return (model, maySpend) }
            throw ToolInputError("There's no picture model called \(wanted). Call list_media_models to see them.")
        }
        if chooseAutomatically, let best = ImageModelChooser.best(for: isEdit ? .edit : .new, among: candidates) {
            return (best.id, !best.isFree)
        }
        return (model, maySpend)
    }

    public var spec: ToolSpec {
        var properties: [String: JSONValue] = [
            "prompt": ["type": "string", "description": "A detailed prompt written for the model: subject, style, composition, light, any exact text. For an edit, say what changes and that everything else stays the same."],
            "aspect_ratio": ["type": "string", "enum": ["1:1", "3:4", "4:3", "16:9", "9:16"]],
            "quality": ["type": "string", "enum": ["standard", "high"]],
        ]
        if !candidates.isEmpty {
            properties["model"] = ["type": "string", "description": "Optional picture model id (see list_media_models), when the person names one. Leave it out and MAIPA-G picks the best for the job: an editing model for edits, the best general model for new pictures."]
        }
        var description = "Generate and save a real picture, or change one from this chat."
        let anyTakesPictures = client.acceptsImageInput(model) != false || candidates.contains(where: \.acceptsImages)
        if !availableImages.isEmpty, anyTakesPictures {
            let names = availableImages.map(\.name)
            properties["reference_images"] = ["type": "array", "items": ["type": "string", "enum": .array(names.map { .string($0) })]]
            description += " To edit or build on pictures from this chat, name them in reference_images."
        }
        return ToolSpec(name: name, description: description, parameters: ["type": "object", "properties": .object(properties), "required": ["prompt"]])
    }

    /// The named chat pictures, read from the store. An unknown name is an error the model can fix.
    func inputImages(named names: [String]) async throws -> [ImageInput] {
        var inputs: [ImageInput] = []
        for name in names {
            guard let reference = availableImages.first(where: { $0.name == name || $0.id.uuidString.lowercased() == name.lowercased() }) else {
                throw ToolInputError("There is no picture called \(name) in this chat. Pictures here: \(availableImages.map(\.name).joined(separator: ", ")).")
            }
            inputs.append(ImageInput(name: reference.name, mimeType: reference.mimeType, data: try await store.data(for: reference)))
        }
        return inputs
    }
    public func runningSummary(for arguments: JSONValue) -> String { "Generating a picture…" }
    // No extra "spend money?" question (owner, 6 November 2026: "They don't stop to say it cost
    // money… it just runs"). The stop-and-ask amount in Settings still applies, as it does to
    // everything: the picture's cost counts toward the reply before the next request.
    public func run(arguments: JSONValue, progress: @escaping @Sendable (String) -> Void) async throws -> ToolOutput {
        let prompt = try arguments.requiredString("prompt")
        let model = try resolvedModel(arguments).id
        let aspect = arguments.optionalString("aspect_ratio").flatMap(ImageAspectRatio.init(rawValue:)) ?? .square
        let quality = arguments.optionalString("quality").flatMap(ImageQuality.init(rawValue:)) ?? .standard
        let referenceNames = arguments["reference_images"]?.arrayValue?.compactMap(\.stringValue) ?? []
        let inputs = try await inputImages(named: referenceNames)
        // When MAIPA-G picked the model, a picture service that's down for a moment (TeamoRouter's
        // "temporarily unable … retry shortly", 7 times on 11 November 2026) is tried once more,
        // then the next best model is used, on another provider first. A model the person named
        // is only retried.
        let named = arguments.optionalString("model").map { !$0.isEmpty && $0.lowercased() != "auto" } ?? false
        let job: ImageModelChooser.Job = inputs.isEmpty ? .new : .edit
        let backups = chooseAutomatically && !named
            ? ImageModelChooser.ranked(for: job, among: candidates).map(\.id).filter { $0 != model }
            : []
        let options = ImageGenerationOptions(aspectRatio: aspect, quality: quality)
        var generated: [GeneratedImage] = []
        var used = model
        var skippedProviders = Set<String>()
        var lastError: Error?
        var fellBackFrom: [String] = []
        for candidate in ([model] + backups) {
            if fellBackFrom.count >= 4 { break }
            let provider = AIProviderModelID.providerID(candidate)
            if skippedProviders.contains(provider) { continue }
            do {
                generated = try await Self.retryingOnce {
                    try await client.generateImages(prompt: prompt, model: candidate, options: options, inputImages: inputs, progress: progress)
                }
                used = candidate
                lastError = nil
                break
            } catch {
                if error is CancellationError || Task.isCancelled { throw error }
                guard let reason = Self.tryAnother(error) else { throw error }
                lastError = error
                fellBackFrom.append(candidate)
                // No credit or a dead service on one provider: its other models won't do better.
                if reason == .provider { skippedProviders.insert(provider) }
                progress("That picture service didn't answer, trying another…")
            }
        }
        if let lastError, generated.isEmpty { throw lastError }
        var results: [GeneratedImageResult] = []
        for image in generated {
            let ext = image.mimeType.contains("jpeg") || image.mimeType.contains("jpg") ? "jpg" : (image.mimeType.contains("webp") ? "webp" : "png")
            let reference = try await store.importGeneratedImage(image.data, name: "picture-\(image.id.uuidString.lowercased()).\(ext)", mimeType: image.mimeType)
            let result = GeneratedImageResult(attachment: reference, prompt: image.prompt, model: image.model, aspectRatio: aspect.rawValue, quality: quality.rawValue, cost: image.cost)
            try await store.saveGeneratedMetadata(result)
            results.append(result)
        }
        let cost = results.compactMap(\.cost).reduce(0, +)
        let fallbackNote = fellBackFrom.isEmpty ? "" : " (\(fellBackFrom.joined(separator: ", ")) didn't answer, so \(used) made it)"
        var details: [String] = []
        if cost > 0 { details.append("Cost: $\(String(format: "%.4f", cost))") }
        if !fellBackFrom.isEmpty { details.append("Made with \(used) because \(fellBackFrom.joined(separator: ", ")) didn't answer.") }
        return ToolOutput(
            forModel: "Generated \(results.count) saved picture(s) using \(used)" + (inputs.isEmpty ? "" : " from " + inputs.map(\.name).joined(separator: ", ")) + fallbackNote + ".",
            summary: results.count == 1 ? "Generated a picture" : "Generated \(results.count) pictures",
            detail: details.isEmpty ? nil : details.joined(separator: " "),
            generatedImages: results,
            billedCost: cost
        )
    }

    enum Retry { case model, provider }

    /// Whether another picture model may succeed where this one failed, and whether to skip the
    /// rest of that provider. Nil for a request no model can take (a refused prompt, a bad picture).
    static func tryAnother(_ error: Error) -> Retry? {
        if let api = error as? OpenRouterAPIError {
            if api.kind == .outOfCredits || api.kind == .spendingCapReached || api.kind == .invalidKey { return .provider }
            if api.isTemporary { return (Int(api.code) ?? api.httpStatus) >= 500 ? .provider : .model }
            if api.kind == .noModelAvailable || api.kind == .appRestricted { return .model }
            return nil
        }
        if error is ImageInputNotSupported { return .model }
        if let http = error as? HTTPError {
            if http.isOffline { return nil }
            if case .transport = http { return .model }
            if let status = http.statusCode, status >= 500 || status == 429 { return .provider }
        }
        return nil
    }

    /// One more try after a short wait when the service said it's down for a moment.
    static func retryingOnce<T: Sendable>(_ work: @Sendable () async throws -> T) async throws -> T {
        do { return try await work() }
        catch {
            if error is CancellationError { throw error }
            let wait: TimeInterval
            if let api = error as? OpenRouterAPIError, api.isTemporary { wait = min(api.retryAfter ?? 2, 10) }
            else if let http = error as? HTTPError, case .transport = http, !http.isOffline { wait = 2 }
            else { throw error }
            try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            return try await work()
        }
    }
}
