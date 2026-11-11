import Foundation

// MARK: Choosing the picture model

/// Picks a picture model for the job when the person didn't name one (owner, 11 November 2026:
/// "just make it pick the best for whatever the situation calls for, whether that be an edit, a
/// whole new picture, etc."). It used to take the first picture model in the catalogue, whatever
/// that was. Better-known models come first; an edit needs one that takes pictures in.
public enum ImageModelChooser {
    public enum Job: Sendable { case new, edit }

    /// Families in order of preference, matched against the model id. Editing favours the models
    /// that keep the rest of the picture as it was.
    static let editPreference = [
        "gemini-3-pro-image", "gpt-image-2", "gpt-image", "nano-banana-pro", "nano-banana", "gemini-3-flash-image",
        "gemini-2.5-flash-image", "seedream", "flux-kontext", "flux-2", "qwen-image-edit", "gpt-5-image", "gemini",
    ]
    static let newPreference = [
        "gpt-image-2", "gpt-image", "gemini-3-pro-image", "nano-banana-pro", "seedream", "flux-2", "imagen",
        "gemini-3-flash-image", "nano-banana", "ideogram", "recraft", "flux", "gemini-2.5-flash-image", "gpt-5-image", "qwen-image",
    ]

    public static func best(for job: Job, among models: [ModelInfo]) -> ModelInfo? {
        let usable = models.filter { $0.generatesImages && (job == .new || $0.acceptsImages) }
        let pool = usable.isEmpty && job == .edit ? models.filter(\.generatesImages) : usable
        let order = job == .edit ? editPreference : newPreference
        func rank(_ model: ModelInfo) -> Int {
            let id = AIProviderModelID.rawModelID(model.id).lowercased()
            return order.firstIndex { id.contains($0) } ?? order.count
        }
        // Equal families: a paid model before its free twin (free ones are rate-limited hard), then
        // the newest.
        return pool.min { a, b in
            let ra = rank(a), rb = rank(b)
            if ra != rb { return ra < rb }
            if a.isFree != b.isFree { return !a.isFree }
            return (a.created ?? .distantPast) > (b.created ?? .distantPast)
        }
    }

    /// The model the person named ("use Nano Banana for this"), by id, name or a close part of it.
    public static func named(_ text: String, among models: [ModelInfo]) -> ModelInfo? {
        let wanted = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else { return nil }
        if let exact = models.first(where: { $0.id.lowercased() == wanted || AIProviderModelID.rawModelID($0.id).lowercased() == wanted }) { return exact }
        if let byName = models.first(where: { $0.name.lowercased() == wanted || $0.shortName.lowercased() == wanted }) { return byName }
        let squeezed = wanted.filter { $0.isLetter || $0.isNumber }
        return models.first { model in
            let id = model.id.lowercased().filter { $0.isLetter || $0.isNumber }
            let name = model.name.lowercased().filter { $0.isLetter || $0.isNumber }
            return !squeezed.isEmpty && (id.contains(squeezed) || name.contains(squeezed))
        }
    }
}

// MARK: Video models

/// One video model from OpenRouter's GET /api/v1/videos/models.
public struct VideoModelInfo: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var durations: [Int]
    public var resolutions: [String]
    public var aspectRatios: [String]
    /// Dollars per second of video at the cheapest resolution, when the catalogue says.
    public var pricePerSecond: Double?
    public var takesFirstFrame: Bool

    public init(id: String, name: String, durations: [Int] = [], resolutions: [String] = [], aspectRatios: [String] = [], pricePerSecond: Double? = nil, takesFirstFrame: Bool = true) {
        self.id = id; self.name = name; self.durations = durations; self.resolutions = resolutions
        self.aspectRatios = aspectRatios; self.pricePerSecond = pricePerSecond; self.takesFirstFrame = takesFirstFrame
    }

    static func parse(_ value: JSONValue) -> VideoModelInfo? {
        guard let id = value["id"]?.stringValue else { return nil }
        let skus = value["pricing_skus"]?.objectValue ?? [:]
        let prices = skus.filter { $0.key.contains("second") }.compactMap { Double($0.value.stringValue ?? "") ?? $0.value.doubleValue }
        return VideoModelInfo(
            id: id,
            name: value["name"]?.stringValue ?? id,
            durations: value["supported_durations"]?.arrayValue?.compactMap { $0.intValue } ?? [],
            resolutions: value["supported_resolutions"]?.arrayValue?.compactMap(\.stringValue) ?? [],
            aspectRatios: value["supported_aspect_ratios"]?.arrayValue?.compactMap(\.stringValue) ?? [],
            pricePerSecond: prices.min(),
            takesFirstFrame: value["supports_frame_images"]?.boolValue ?? true
        )
    }

    static let preference = ["veo-3.1", "veo", "kling", "seedance-2.5", "seedance", "sora-2", "hailuo", "wan", "runway", "heygen"]

    public static func best(among models: [VideoModelInfo], fromPicture: Bool) -> VideoModelInfo? {
        let pool = fromPicture ? models.filter(\.takesFirstFrame) : models
        func rank(_ model: VideoModelInfo) -> Int { preference.firstIndex { model.id.lowercased().contains($0) } ?? preference.count }
        return (pool.isEmpty ? models : pool).min { a, b in
            let ra = rank(a), rb = rank(b)
            if ra != rb { return ra < rb }
            return (a.pricePerSecond ?? 1) < (b.pricePerSecond ?? 1)
        }
    }
}

public struct GeneratedVideo: Sendable, Hashable {
    public var data: Data
    public var mimeType: String
    public var cost: Double?
}

public extension OpenRouterClient {
    func videoModels() async throws -> [VideoModelInfo] {
        let response = try await transport.send(HTTPRequest(url: Self.apiBase.appendingPathComponent("videos/models"), headers: headers(forModel: nil), idleTimeout: 60))
        guard response.isSuccess else { throw OpenRouterAPIError(status: response.status, body: response.body, headers: response.headers) }
        return JSONValue.parse(response.body)?["data"]?.arrayValue?.compactMap(VideoModelInfo.parse) ?? []
    }

    /// OpenRouter makes videos as a job: start it, check on it, then download the result
    /// (openrouter.ai/docs/guides/overview/multimodal/video-generation).
    func generateVideo(
        prompt: String, model: String, duration: Int?, resolution: String?, aspectRatio: String?,
        firstFrame: ImageInput?, pollEvery: TimeInterval = 10, giveUpAfter: TimeInterval = 900,
        progress: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> GeneratedVideo {
        var fields: [String: JSONValue] = ["model": .string(model), "prompt": .string(prompt)]
        if let duration { fields["duration"] = .number(Double(duration)) }
        if let resolution { fields["resolution"] = .string(resolution) }
        if let aspectRatio { fields["aspect_ratio"] = .string(aspectRatio) }
        if let firstFrame {
            fields["frame_images"] = [["type": "image_url", "image_url": ["url": .string(firstFrame.dataURL)], "frame_type": "first_frame"]]
        }
        progress("Starting the video…")
        let body = JSONValue.object(fields)
        let start = try await transport.send(try HTTPRequest.json("POST", Self.apiBase.appendingPathComponent("videos"), body: body, headers: headers(forModel: model), idleTimeout: 120))
        guard start.isSuccess, let job = JSONValue.parse(start.body), let id = job["id"]?.stringValue else {
            throw OpenRouterAPIError(status: start.status, body: start.body, headers: start.headers)
        }
        let pollURL = job["polling_url"]?.stringValue.flatMap(URL.init(string:)).flatMap { $0.host == Self.apiBase.host ? $0 : nil }
            ?? Self.apiBase.appendingPathComponent("videos/\(id)")
        let started = Date()
        var status = job["status"]?.stringValue ?? "pending"
        var latest = job
        while status != "completed" {
            if ["failed", "cancelled", "expired"].contains(status) {
                throw ToolInputError("The video didn't get made: \(latest["error"]?.stringValue ?? status).")
            }
            guard Date().timeIntervalSince(started) < giveUpAfter else {
                throw ToolInputError("The video was still being made after \(Int(giveUpAfter / 60)) minutes, so MAIPA-G stopped waiting.")
            }
            try await Task.sleep(nanoseconds: UInt64(pollEvery * 1_000_000_000))
            progress("Making the video… \(Int(Date().timeIntervalSince(started)))s")
            let poll = try await transport.send(HTTPRequest(url: pollURL, headers: headers(forModel: model), idleTimeout: 60))
            guard poll.isSuccess, let value = JSONValue.parse(poll.body) else {
                if poll.status >= 500 { continue }
                throw OpenRouterAPIError(status: poll.status, body: poll.body, headers: poll.headers)
            }
            latest = value
            status = value["status"]?.stringValue ?? status
        }
        let contentURL = latest["unsigned_urls"]?.arrayValue?.first?.stringValue.flatMap(URL.init(string:)).flatMap { $0.host == Self.apiBase.host ? $0 : nil }
            ?? Self.apiBase.appendingPathComponent("videos/\(id)/content")
        progress("Saving the video…")
        let download = try await transport.send(HTTPRequest(url: contentURL, headers: headers(forModel: model), idleTimeout: 300))
        guard download.isSuccess, !download.body.isEmpty else { throw OpenRouterAPIError(status: download.status, body: download.body, headers: download.headers) }
        let mime = download.headers["content-type"].flatMap { $0.hasPrefix("video/") ? $0 : nil } ?? "video/mp4"
        return GeneratedVideo(data: download.body, mimeType: mime, cost: latest["usage"]?["cost"]?.doubleValue)
    }
}

// MARK: Tools

/// Lists the picture and video models the person can use, so the AI can answer "what models are
/// there?" and pick the one they name.
public struct ListMediaModelsTool: AgentTool {
    public let name = "list_media_models"
    let imageModels: [ModelInfo]
    let videoModels: @Sendable () async -> [VideoModelInfo]

    public init(imageModels: [ModelInfo], videoModels: @escaping @Sendable () async -> [VideoModelInfo]) {
        self.imageModels = imageModels.filter(\.generatesImages)
        self.videoModels = videoModels
    }

    public var spec: ToolSpec {
        ToolSpec(name: name, description: "List the picture and video models available, with what each can do and its price. Use it when the person asks which models there are, or names one to use.", parameters: [
            "type": "object", "properties": ["kind": ["type": "string", "enum": ["pictures", "videos", "both"]]], "additionalProperties": false,
        ])
    }

    public func runningSummary(for arguments: JSONValue) -> String { "Looking up picture and video models…" }

    public func run(arguments: JSONValue, progress: @escaping @Sendable (String) -> Void) async throws -> ToolOutput {
        let kind = arguments["kind"]?.stringValue ?? "both"
        var lines: [String] = []
        if kind != "videos" {
            let bestNew = ImageModelChooser.best(for: .new, among: imageModels)?.id
            let bestEdit = ImageModelChooser.best(for: .edit, among: imageModels)?.id
            lines.append("Picture models (\(imageModels.count)):")
            for model in imageModels.sorted(by: { $0.name < $1.name }) {
                var notes: [String] = []
                if model.acceptsImages { notes.append("edits pictures") }
                if model.isFree { notes.append("free") }
                if model.id == bestNew { notes.append("default for new pictures") }
                if model.id == bestEdit { notes.append("default for edits") }
                lines.append("- \(model.name) (`\(model.id)`)\(notes.isEmpty ? "" : ": " + notes.joined(separator: ", "))")
            }
        }
        if kind != "pictures" {
            let videos = await videoModels()
            lines.append(videos.isEmpty ? "Video models: none available (videos need an OpenRouter account)." : "Video models (\(videos.count)):")
            for video in videos.sorted(by: { $0.name < $1.name }) {
                var notes: [String] = []
                if let price = video.pricePerSecond { notes.append("about $\(String(format: "%.2f", price)) a second") }
                if !video.durations.isEmpty { notes.append("\(video.durations.map(String.init).joined(separator: "/")) s") }
                if !video.resolutions.isEmpty { notes.append(video.resolutions.joined(separator: "/")) }
                lines.append("- \(video.name) (`\(video.id)`)\(notes.isEmpty ? "" : ": " + notes.joined(separator: ", "))")
            }
        }
        let text = lines.joined(separator: "\n")
        return ToolOutput(forModel: text, summary: "Listed picture and video models", detail: text)
    }
}

/// Makes a video from words, or from a picture in the chat as its first frame, and saves it with
/// the chat.
public struct GenerateVideoTool: AgentTool {
    public let name = "generate_video"
    let client: OpenRouterClient
    let store: AttachmentStore
    let availableImages: [AttachmentReference]
    let models: @Sendable () async -> [VideoModelInfo]

    public init(client: OpenRouterClient, store: AttachmentStore, availableImages: [AttachmentReference], models: @escaping @Sendable () async -> [VideoModelInfo]) {
        self.client = client
        self.store = store
        self.availableImages = availableImages.filter { $0.kind == .image }
        self.models = models
    }

    public var spec: ToolSpec {
        var properties: [String: JSONValue] = [
            "prompt": ["type": "string", "description": "What happens in the video: subject, motion, camera, light."],
            "model": ["type": "string", "description": "Optional video model id from list_media_models. Leave it out and MAIPA-G picks a good one."],
            "duration_seconds": ["type": "integer", "description": "Optional; short (4 to 8 seconds) unless the person asks for longer."],
            "aspect_ratio": ["type": "string", "enum": ["16:9", "9:16", "1:1"]],
            "resolution": ["type": "string", "enum": ["480p", "720p", "1080p"]],
        ]
        if !availableImages.isEmpty {
            properties["first_frame"] = ["type": "string", "enum": .array(availableImages.map { .string($0.name) }), "description": "A picture from this chat to start the video from."]
        }
        return ToolSpec(name: name, description: "Make a real video (it takes a minute or more) and save it with the chat. Videos are billed by the second, so keep them short unless asked.", parameters: [
            "type": "object", "properties": .object(properties), "required": ["prompt"], "additionalProperties": false,
        ])
    }

    public func runningSummary(for arguments: JSONValue) -> String { "Making a video…" }

    func resolve(_ arguments: JSONValue) async throws -> VideoModelInfo {
        let all = await models()
        guard !all.isEmpty else { throw ToolInputError("No video models are available. Videos need an OpenRouter account with credit.") }
        if let wanted = arguments.optionalString("model"), !wanted.isEmpty {
            let squeezed = wanted.lowercased().filter { $0.isLetter || $0.isNumber }
            if let match = all.first(where: { $0.id.lowercased() == wanted.lowercased() })
                ?? all.first(where: { $0.id.lowercased().filter { $0.isLetter || $0.isNumber }.contains(squeezed) || $0.name.lowercased().filter { $0.isLetter || $0.isNumber }.contains(squeezed) }) {
                return match
            }
            throw ToolInputError("There's no video model called \(wanted). Available: \(all.map(\.id).joined(separator: ", ")).")
        }
        guard let best = VideoModelInfo.best(among: all, fromPicture: arguments.optionalString("first_frame") != nil) else {
            throw ToolInputError("No video models are available.")
        }
        return best
    }

    static func seconds(_ arguments: JSONValue, model: VideoModelInfo) -> Int? {
        let asked = arguments["duration_seconds"]?.intValue
        guard !model.durations.isEmpty else { return asked }
        let target = asked ?? 5
        return model.durations.min { abs($0 - target) < abs($1 - target) }
    }

    /// What a video will cost, for the tool's own result (no question is asked before spending;
    /// the stop-and-ask amount in Settings applies as it does everywhere).
    static func estimate(_ arguments: JSONValue, model: VideoModelInfo) -> String {
        let seconds = Self.seconds(arguments, model: model) ?? 5
        return model.pricePerSecond.map { "about $\(String(format: "%.2f", $0 * Double(seconds))) for \(seconds) seconds" } ?? "\(seconds) seconds"
    }

    public func run(arguments: JSONValue, progress: @escaping @Sendable (String) -> Void) async throws -> ToolOutput {
        try await runApproved(arguments: arguments, progress: progress)
    }

    public func runApproved(arguments: JSONValue, progress: @escaping @Sendable (String) -> Void) async throws -> ToolOutput {
        let prompt = try arguments.requiredString("prompt")
        let model = try await resolve(arguments)
        var firstFrame: ImageInput?
        if let name = arguments.optionalString("first_frame") {
            guard let picture = availableImages.first(where: { $0.name == name }) else {
                throw ToolInputError("There is no picture called \(name) in this chat. Pictures here: \(availableImages.map(\.name).joined(separator: ", ")).")
            }
            firstFrame = ImageInput(name: picture.name, mimeType: picture.mimeType, data: try await store.data(for: picture))
        }
        let video = try await client.generateVideo(
            prompt: prompt, model: model.id, duration: Self.seconds(arguments, model: model),
            resolution: arguments.optionalString("resolution"), aspectRatio: arguments.optionalString("aspect_ratio"),
            firstFrame: firstFrame, progress: progress
        )
        progress("Saved (\(Self.estimate(arguments, model: model)))")
        let ext = video.mimeType.contains("webm") ? "webm" : (video.mimeType.contains("quicktime") ? "mov" : "mp4")
        let id = UUID()
        let reference = try await store.importGeneratedMedia(video.data, name: "video-\(id.uuidString.lowercased()).\(ext)", mimeType: video.mimeType, kind: .file)
        let result = GeneratedImageResult(attachment: reference, prompt: prompt, model: model.id, aspectRatio: arguments.optionalString("aspect_ratio") ?? "", quality: arguments.optionalString("resolution") ?? "", cost: video.cost)
        try await store.saveGeneratedMetadata(result)
        return ToolOutput(
            forModel: "Made a video with \(model.name) and saved it with the chat as \(reference.name)." + (firstFrame.map { " It starts from \($0.name)." } ?? ""),
            summary: "Made a video",
            detail: video.cost.map { "Cost: $\(String(format: "%.4f", $0))" },
            generatedImages: [result],
            billedCost: video.cost ?? 0
        )
    }
}

public extension GeneratedImageResult {
    /// Videos are kept with the chat's pictures (in media/, backed up the same way); this tells
    /// them apart.
    var isVideo: Bool { attachment.mimeType.hasPrefix("video/") }
}

/// Video models change rarely; they're looked up once an hour.
public actor VideoCatalogue {
    public static let shared = VideoCatalogue()
    private var cached: (models: [VideoModelInfo], at: Date)?

    public func models(using client: OpenRouterClient) async -> [VideoModelInfo] {
        if let cached, Date().timeIntervalSince(cached.at) < 3_600, !cached.models.isEmpty { return cached.models }
        let fresh = (try? await client.videoModels()) ?? []
        if !fresh.isEmpty { cached = (fresh, Date()) }
        return fresh.isEmpty ? (cached?.models ?? []) : fresh
    }
}

/// Pictures and videos are made by the phone (the chat computer has no picture tools), so a
/// reply that is about them stays on the phone.
public enum MediaRequest {
    static let words: Set<String> = [
        "picture", "pictures", "pic", "pics", "image", "images", "photo", "photos", "draw", "drawing", "logo", "logos",
        "icon", "icons", "wallpaper", "sticker", "illustration", "illustrate", "artwork", "poster", "thumbnail",
        "video", "videos", "clip", "animate", "animation", "upscale", "background", "recolor", "recolour",
    ]

    /// `hasImageAttachments`: this message has photos. `chatHasPictures`: the chat already has
    /// pictures the message may be about ("make it bluer").
    public static func wanted(_ text: String, hasImageAttachments: Bool, chatHasPictures: Bool = false) -> Bool {
        let tokens = text.lowercased().components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty }
        if !Set(tokens).isDisjoint(with: words) { return true }
        let refersToPicture = ImageEditIntent.refersToEarlierPicture(text)
        // A photo with a short instruction ("make it black", "I want the white to be black and
        // the black to be white") is an edit.
        if hasImageAttachments, tokens.count <= 30 || refersToPicture { return true }
        return chatHasPictures && refersToPicture
    }
}
