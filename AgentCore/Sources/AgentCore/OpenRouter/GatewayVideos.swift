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
        // 1. OpenAI's address, POST /videos, always as JSON: OneProvider refuses a form upload with
        // "request body must be a JSON object" (12 November 2026, every video from a picture). A
        // first frame goes in as a data address.
        var fields: [String: JSONValue] = [
            "model": .string(rawModelID), "prompt": .string(prompt), "seconds": .string(String(seconds)), "size": .string(size),
            "duration": .number(Double(seconds)),
        ]
        if let aspectRatio { fields["aspect_ratio"] = .string(aspectRatio) }
        if let firstFrame {
            fields["image"] = .string(firstFrame.dataURL)
            fields["input_reference"] = .string(firstFrame.dataURL)
        }
        let body = JSONValue.object(fields)
        var started = try await transport.send(try HTTPRequest.json("POST", base.appendingPathComponent("videos"), body: body, headers: headers, idleTimeout: 180))
        var route = Route.openAI
        // 2. The task address many gateways use: POST /video/generations.
        if [404, 405, 501].contains(started.status) {
            started = try await transport.send(try HTTPRequest.json("POST", base.appendingPathComponent("video/generations"), body: body, headers: headers, idleTimeout: 180))
            route = .tasks
            if [404, 405, 501].contains(started.status) {
                throw OpenRouterAPIError(httpStatus: started.status, code: "video_unsupported", message: "\(endpoint.name) doesn't take video requests (it has no /videos or /video/generations address).", providerName: endpoint.name)
            }
        }
        guard started.isSuccess, let job = JSONValue.parse(started.body) else {
            throw OpenRouterAPIError(status: started.status, body: started.body, headers: started.headers, providerName: endpoint.name)
        }
        if case .failed(let reason) = videoState(job) {
            throw OpenRouterAPIError(httpStatus: 502, code: "video_failed", message: "The video didn't get made on \(endpoint.name): \(reason).", providerName: endpoint.name)
        }
        var latest = job
        if let ready = try await finishedVideo(in: latest, base: base, headers: headers, transport: transport) { return ready }
        let pollURLs = pollAddresses(for: job, route: route, base: base)
        guard !pollURLs.isEmpty else {
            // Say what came back, so the next try can be fixed from it.
            let shown = SensitiveDataRedactor().redact(String(decoding: started.body.prefix(400), as: UTF8.self))
            throw OpenRouterAPIError(httpStatus: 502, code: "video_no_id", message: "\(endpoint.name) answered the video request without a job to check on. It said: \(shown)", providerName: endpoint.name)
        }
        var pollIndex = 0
        let startedAt = Date()
        while true {
            switch videoState(latest) {
            case .failed(let reason):
                throw OpenRouterAPIError(httpStatus: 502, code: "video_failed", message: "The video didn't get made on \(endpoint.name): \(reason).", providerName: endpoint.name)
            case .done:
                if let ready = try await finishedVideo(in: latest, base: base, headers: headers, transport: transport) { return ready }
                if let id = jobID(in: job) {
                    for path in ["videos/\(id)/content", "video/generations/\(id)/content"] {
                        let download = try await transport.send(HTTPRequest(url: base.appendingPathComponent(path), headers: headers, idleTimeout: 300))
                        if download.isSuccess, !download.body.isEmpty, download.headers["content-type"]?.hasPrefix("application/json") != true {
                            return video(from: download, cost: cost(in: latest))
                        }
                    }
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
            let poll = try await transport.send(HTTPRequest(url: pollURLs[pollIndex], headers: headers, idleTimeout: 60))
            guard poll.isSuccess, let value = JSONValue.parse(poll.body) else {
                // Checked at an address the gateway doesn't have: try its other one.
                if [400, 404, 405].contains(poll.status), pollIndex + 1 < pollURLs.count { pollIndex += 1; continue }
                if poll.status >= 500 || poll.status == 429 { continue }
                throw OpenRouterAPIError(status: poll.status, body: poll.body, headers: poll.headers, providerName: endpoint.name)
            }
            latest = value
        }
    }

    /// The job's id, wherever the gateway put it.
    static func jobID(in job: JSONValue) -> String? {
        let keys = ["id", "task_id", "taskId", "video_id", "videoId", "job_id", "jobId", "generation_id", "generationId"]
        let places: [JSONValue?] = [job, job["data"], job["output"], job["result"], job["task"], job["data"]?.arrayValue?.first, job["data"]?["task"]]
        for place in places.compactMap({ $0 }) {
            for key in keys {
                if let value = place[key]?.stringValue, !value.isEmpty { return value }
                if let number = place[key]?.intValue { return String(number) }
            }
        }
        return nil
    }

    /// Where to check on the job: an address it gave (same host only), then the usual ones.
    static func pollAddresses(for job: JSONValue, route: Route, base: URL) -> [URL] {
        var urls: [URL] = []
        for key in ["polling_url", "status_url", "poll_url", "query_url"] {
            for place in [job, job["data"]].compactMap({ $0 }) {
                if let text = place[key]?.stringValue, let url = URL(string: text), url.scheme == "https", url.host?.lowercased() == base.host?.lowercased() {
                    urls.append(url)
                }
            }
        }
        if let id = jobID(in: job) {
            let own = route == .openAI ? "videos/\(id)" : "video/generations/\(id)"
            let other = route == .openAI ? "video/generations/\(id)" : "videos/\(id)"
            urls.append(base.appendingPathComponent(own))
            urls.append(base.appendingPathComponent(other))
        }
        var seen = Set<URL>()
        return urls.filter { seen.insert($0).inserted }
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
            job["data"]?["task_result"]?["videos"]?.arrayValue?.first?["url"], job["task_result"]?["videos"]?.arrayValue?.first?["url"],
            job["output"]?["video_url"], job["result"]?["url"], job["result"]?["video_url"], job["data"]?["result"]?["url"],
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
        // Some gateways hand the video straight back, in base64.
        for place in [job, job["data"]?.arrayValue?.first, job["data"], job["output"]].compactMap({ $0 }) {
            for key in ["b64_json", "video_base64", "b64", "base64"] {
                if let text = place[key]?.stringValue, let data = Data(base64Encoded: text), data.count > 1_000 {
                    return GeneratedVideo(data: data, mimeType: "video/mp4", cost: cost(in: job))
                }
            }
        }
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
}
