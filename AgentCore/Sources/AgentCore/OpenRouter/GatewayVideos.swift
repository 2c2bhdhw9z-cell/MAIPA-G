import Foundation

// MARK: Videos through the connected gateways

/// Videos used to come only from OpenRouter, so with no OpenRouter credit there was no way to
/// make one even with OneProvider connected (owner, 11 November 2026: "OneProvider and TeamoRouter
/// are connected, but this video tool still doesn't expose a route through them").
///
/// OneProvider lists Kling 3.0 and Kling 3.0 Turbo as video models in its catalogue
/// (oneprovider.dev/docs/llms.txt, catalogue revision 2026-11-08.2) but doesn't document the
/// address. MAIPA-G asks the OpenAI-style `/videos` first and the `/video/generations` task route
/// many gateways use second, and says plainly if the gateway has neither. TeamoRouter lists no
/// video models.
public extension AIProviderGateway {
    /// Video models each gateway is known to offer: raw id and name.
    static let knownVideoModels: [String: [(id: String, name: String)]] = [
        "oneprovider": [("kling-3.0", "Kling 3.0"), ("kling-3.0-turbo", "Kling 3.0 Turbo")],
    ]

    static func videoModels(for endpoint: AIProviderEndpoint) -> [VideoModelInfo] {
        guard endpoint.isReady else { return [] }
        let key = endpoint.id == "oneprovider" || endpoint.baseURL.lowercased().contains("oneprovider.dev") ? "oneprovider" : endpoint.id
        return (knownVideoModels[key] ?? []).map { model in
            VideoModelInfo(
                id: AIProviderModelID.encode(providerID: endpoint.id, rawModelID: model.id),
                name: "\(model.name) · \(endpoint.name)",
                durations: [5, 10],
                aspectRatios: ["16:9", "9:16", "1:1"],
                takesFirstFrame: true
            )
        }
    }

    /// Starts the video, checks on it until it's ready, and downloads it.
    static func generateVideo(
        prompt: String, rawModelID: String, duration: Int?, aspectRatio: String?, firstFrame: ImageInput?,
        endpoint: AIProviderEndpoint, transport: any HTTPTransport,
        pollEvery: TimeInterval = 10, giveUpAfter: TimeInterval = 900,
        progress: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> GeneratedVideo {
        guard let base = endpoint.normalizedURL else {
            throw OpenRouterAPIError(httpStatus: 400, code: "invalid_url", message: "Invalid base URL for \(endpoint.name).")
        }
        try validateEndpointURL(base)
        let key = AIProviderEndpoint.sanitizeAPIKey(endpoint.apiKey)
        var headers = ["Accept": "application/json"]
        if !key.isEmpty { headers["Authorization"] = "Bearer \(key)" }
        let seconds = duration ?? 5
        let size: String = switch aspectRatio {
        case "9:16": "720x1280"
        case "1:1": "1024x1024"
        default: "1280x720"
        }

        progress("Starting the video…")
        // 1. OpenAI's shape: POST /videos (multipart when a first frame is given).
        let openAIStyle: HTTPRequest
        if let firstFrame {
            openAIStyle = multipart(url: base.appendingPathComponent("videos"), fields: [
                "model": rawModelID, "prompt": prompt, "seconds": String(seconds), "size": size,
            ], file: ("input_reference", firstFrame), headers: headers)
        } else {
            let body: JSONValue = [
                "model": .string(rawModelID), "prompt": .string(prompt), "seconds": .string(String(seconds)), "size": .string(size),
            ]
            openAIStyle = try HTTPRequest.json("POST", base.appendingPathComponent("videos"), body: body, headers: headers, idleTimeout: 120)
        }
        var started = try await transport.send(openAIStyle)
        var route = Route.openAI
        // 2. The task route: POST /video/generations.
        if [404, 405, 501].contains(started.status) {
            var fields: [String: JSONValue] = ["model": .string(rawModelID), "prompt": .string(prompt), "duration": .number(Double(seconds))]
            if let aspectRatio { fields["aspect_ratio"] = .string(aspectRatio) }
            if let firstFrame { fields["image"] = .string(firstFrame.dataURL) }
            let body = JSONValue.object(fields)
            started = try await transport.send(try HTTPRequest.json("POST", base.appendingPathComponent("video/generations"), body: body, headers: headers, idleTimeout: 120))
            route = .tasks
            if [404, 405, 501].contains(started.status) {
                throw OpenRouterAPIError(httpStatus: started.status, code: "video_unsupported", message: "\(endpoint.name) doesn't take video requests (it has no /videos or /video/generations address).", providerName: endpoint.name)
            }
        }
        guard started.isSuccess, let job = JSONValue.parse(started.body) else {
            throw OpenRouterAPIError(status: started.status, body: started.body, headers: started.headers, providerName: endpoint.name)
        }
        var latest = job
        if let ready = try await finishedVideo(in: latest, base: base, headers: headers, transport: transport) { return ready }
        guard let id = job["id"]?.stringValue ?? job["task_id"]?.stringValue ?? job["data"]?["task_id"]?.stringValue ?? job["data"]?["id"]?.stringValue else {
            throw OpenRouterAPIError(httpStatus: started.status, code: "video_no_id", message: "\(endpoint.name) started a video but didn't say how to check on it.", providerName: endpoint.name)
        }
        let pollURL = route == .openAI ? base.appendingPathComponent("videos/\(id)") : base.appendingPathComponent("video/generations/\(id)")
        let startedAt = Date()
        while true {
            switch videoState(latest) {
            case .failed(let reason):
                throw ToolInputError("The video didn't get made on \(endpoint.name): \(reason).")
            case .done:
                if let ready = try await finishedVideo(in: latest, base: base, headers: headers, transport: transport) { return ready }
                if route == .openAI {
                    let download = try await transport.send(HTTPRequest(url: base.appendingPathComponent("videos/\(id)/content"), headers: headers, idleTimeout: 300))
                    if download.isSuccess, !download.body.isEmpty { return video(from: download, cost: cost(in: latest)) }
                    throw OpenRouterAPIError(status: download.status, body: download.body, headers: download.headers, providerName: endpoint.name)
                }
                throw ToolInputError("\(endpoint.name) finished the video but didn't give an address to download it from.")
            case .working:
                break
            }
            guard Date().timeIntervalSince(startedAt) < giveUpAfter else {
                throw ToolInputError("The video was still being made after \(Int(giveUpAfter / 60)) minutes, so MAIPA-G stopped waiting.")
            }
            try await Task.sleep(nanoseconds: UInt64(pollEvery * 1_000_000_000))
            progress("Making the video… \(Int(Date().timeIntervalSince(startedAt)))s")
            let poll = try await transport.send(HTTPRequest(url: pollURL, headers: headers, idleTimeout: 60))
            guard poll.isSuccess, let value = JSONValue.parse(poll.body) else {
                if poll.status >= 500 { continue }
                throw OpenRouterAPIError(status: poll.status, body: poll.body, headers: poll.headers, providerName: endpoint.name)
            }
            latest = value
        }
    }

    // MARK: Reading a video job

    enum Route { case openAI, tasks }
    enum VideoState: Equatable { case working, done, failed(String) }

    static func videoState(_ job: JSONValue) -> VideoState {
        let raw = job["status"]?.stringValue ?? job["data"]?["status"]?.stringValue ?? job["task_status"]?.stringValue ?? job["data"]?["task_status"]?.stringValue ?? ""
        let status = raw.lowercased()
        if ["completed", "succeeded", "success", "succeed", "done", "finished"].contains(status) { return .done }
        if ["failed", "failure", "error", "cancelled", "canceled", "expired"].contains(status) {
            let reason = job["error"]?["message"]?.stringValue ?? job["error"]?.stringValue ?? job["fail_reason"]?.stringValue
                ?? job["data"]?["fail_reason"]?.stringValue ?? job["message"]?.stringValue ?? status
            return .failed(reason)
        }
        if status.isEmpty, videoAddress(in: job) != nil { return .done }
        return .working
    }

    /// Where the finished video is, in the shapes gateways answer with.
    static func videoAddress(in job: JSONValue) -> URL? {
        let candidates: [JSONValue?] = [
            job["url"], job["video_url"], job["result_url"], job["output"]?["url"], job["output"],
            job["data"]?["url"], job["data"]?["video_url"], job["data"]?["output"], job["data"]?["result_url"],
            job["data"]?.arrayValue?.first?["url"], job["data"]?["data"]?.arrayValue?.first?["url"],
            job["videos"]?.arrayValue?.first?["url"], job["data"]?["videos"]?.arrayValue?.first?["url"],
        ]
        for candidate in candidates {
            if let text = candidate?.stringValue, let url = URL(string: text), url.scheme == "https" { return url }
        }
        return nil
    }

    static func cost(in job: JSONValue) -> Double? {
        job["usage"]?["cost"]?.doubleValue ?? job["cost"]?.doubleValue ?? job["data"]?["cost"]?.doubleValue
    }

    /// Downloads the video when the job says where it is. The key goes only to the gateway's own
    /// address, never to a storage host it points at.
    private static func finishedVideo(in job: JSONValue, base: URL, headers: [String: String], transport: any HTTPTransport) async throws -> GeneratedVideo? {
        guard videoState(job) == .done, let address = videoAddress(in: job) else { return nil }
        let sendsKey = address.host?.lowercased() == base.host?.lowercased()
        let download = try await transport.send(HTTPRequest(url: address, headers: sendsKey ? headers : ["Accept": "*/*"], idleTimeout: 300))
        guard download.isSuccess, !download.body.isEmpty else { return nil }
        return video(from: download, cost: cost(in: job))
    }

    private static func video(from download: HTTPResponse, cost: Double?) -> GeneratedVideo {
        let mime = download.headers["content-type"].flatMap { $0.hasPrefix("video/") ? $0 : nil } ?? "video/mp4"
        return GeneratedVideo(data: download.body, mimeType: mime, cost: cost)
    }

    private static func multipart(url: URL, fields: [String: String], file: (name: String, image: ImageInput), headers: [String: String]) -> HTTPRequest {
        let boundary = "maipag-\(UUID().uuidString)"
        var body = Data()
        for (name, value) in fields.sorted(by: { $0.key < $1.key }) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        let ext = file.image.mimeType.contains("png") ? "png" : (file.image.mimeType.contains("webp") ? "webp" : "jpg")
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(file.name)\"; filename=\"first-frame.\(ext)\"\r\nContent-Type: \(file.image.mimeType)\r\n\r\n".utf8))
        body.append(file.image.data)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        var allHeaders = headers
        allHeaders["Content-Type"] = "multipart/form-data; boundary=\(boundary)"
        return HTTPRequest(method: "POST", url: url, headers: allHeaders, body: body, idleTimeout: 300)
    }
}
