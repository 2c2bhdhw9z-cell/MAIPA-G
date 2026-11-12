import Foundation

// MARK: Videos through the connected gateways

/// Videos used to come only from OpenRouter, so with no OpenRouter credit there was no way to
/// make one even with OneProvider connected (owner, 11 November 2026).
///
/// OneProvider's own guide (oneprovider.dev/docs/guides/video-generation, 12 November 2026):
/// POST /v1/videos/generations with model, prompt, duration (5 or 10), resolution (720p or 1080p),
/// aspect_ratio (16:9 or 9:16) and audio; the reply is `{"request_id":"task_…"}`; GET
/// /v1/videos/generations/{id} answers pending, done (with `video.url`, a path on the same host) or
/// failed; the file is at that path. Any other combination is a 400, and 502 means the service is
/// down for a moment. A video is charged once, when it's done.
public extension AIProviderGateway {
    struct KnownVideoModel: Sendable {
        let id: String, name: String, pricePerSecond: Double
    }

    /// Video models each gateway is known to offer.
    static let knownVideoModels: [String: [KnownVideoModel]] = [
        "oneprovider": [
            KnownVideoModel(id: "kling-3.0", name: "Kling 3.0", pricePerSecond: 0.672),
            KnownVideoModel(id: "kling-3.0-turbo", name: "Kling 3.0 Turbo", pricePerSecond: 0.896),
        ],
    ]

    static func isOneProvider(_ endpoint: AIProviderEndpoint) -> Bool {
        endpoint.id == "oneprovider" || endpoint.baseURL.lowercased().contains("oneprovider.dev")
    }

    static func videoModels(for endpoint: AIProviderEndpoint) -> [VideoModelInfo] {
        guard endpoint.isReady else { return [] }
        let key = isOneProvider(endpoint) ? "oneprovider" : endpoint.id
        return (knownVideoModels[key] ?? []).map { model in
            VideoModelInfo(
                id: AIProviderModelID.encode(providerID: endpoint.id, rawModelID: model.id),
                name: "\(model.name) · \(endpoint.name)",
                durations: [5, 10],
                resolutions: ["720p", "1080p"],
                aspectRatios: ["16:9", "9:16"],
                pricePerSecond: model.pricePerSecond,
                takesFirstFrame: true
            )
        }
    }

    /// Starts the video, checks on it until it's ready, and downloads it.
    static func generateVideo(
        prompt: String, rawModelID: String, duration: Int?, aspectRatio: String?, firstFrame: ImageInput?,
        resolution: String? = nil, resumeJob: String? = nil,
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
        let oneProvider = isOneProvider(endpoint)
        // OneProvider takes exactly these; anything else is refused with a 400 (a square video
        // was, three times on 12 November 2026).
        let seconds = oneProvider ? ((duration ?? 5) > 7 ? 10 : 5) : (duration ?? 5)
        let aspect = oneProvider ? (aspectRatio == "9:16" ? "9:16" : "16:9") : aspectRatio
        let quality = oneProvider ? (resolution == "1080p" ? "1080p" : "720p") : resolution
        let startPaths = oneProvider ? ["videos/generations", "videos", "video/generations"] : ["videos", "video/generations", "videos/generations"]

        var job: JSONValue
        var startPath = startPaths[0]
        if let resumeJob, !resumeJob.isEmpty {
            // A video that was already started (and may already be paid for): only collect it.
            progress("Picking up the video…")
            job = ["request_id": .string(resumeJob), "status": "pending"]
        } else {
            progress("Starting the video…")
            var fields: [String: JSONValue] = ["model": .string(rawModelID), "prompt": .string(prompt), "duration": .number(Double(seconds))]
            if let aspect { fields["aspect_ratio"] = .string(aspect) }
            if let quality { fields["resolution"] = .string(quality) }
            if !oneProvider {
                let size: String = switch aspect {
                case "9:16": "720x1280"
                case "1:1": "1024x1024"
                default: "1280x720"
                }
                fields["seconds"] = .string(String(seconds))
                fields["size"] = .string(size)
            }
            if let firstFrame {
                fields["image"] = .string(firstFrame.dataURL)
                if !oneProvider { fields["input_reference"] = .string(firstFrame.dataURL) }
            }
            let body = JSONValue.object(fields)
            var started: HTTPResponse?
            for path in startPaths {
                let response = try await transport.send(try HTTPRequest.json("POST", base.appendingPathComponent(path), body: body, headers: headers, idleTimeout: 180))
                startPath = path
                started = response
                if ![404, 405, 501].contains(response.status) { break }
            }
            guard let started else { throw ToolInputError("The video request couldn't be sent.") }
            if [404, 405, 501].contains(started.status) {
                throw OpenRouterAPIError(httpStatus: started.status, code: "video_unsupported", message: "\(endpoint.name) doesn't take video requests (it has no video address MAIPA-G knows).", providerName: endpoint.name)
            }
            guard started.isSuccess, let parsed = JSONValue.parse(started.body) else {
                throw OpenRouterAPIError(status: started.status, body: started.body, headers: started.headers, providerName: endpoint.name)
            }
            job = parsed
        }
        if case .failed(let reason) = videoState(job) {
            throw OpenRouterAPIError(httpStatus: 502, code: "video_failed", message: "The video didn't get made on \(endpoint.name): \(reason).", providerName: endpoint.name)
        }
        var latest = job
        if let ready = try await finishedVideo(in: latest, base: base, headers: headers, transport: transport) { return ready }
        guard let id = jobID(in: job) else {
            // Say what came back, so the next try can be fixed from it.
            let raw = String(decoding: (try? JSONCoding.encoder().encode(job)) ?? Data(), as: UTF8.self)
            let shown = SensitiveDataRedactor().redact(String(raw.prefix(400)))
            throw OpenRouterAPIError(httpStatus: 502, code: "video_no_id", message: "\(endpoint.name) answered the video request without a job to check on. It said: \(shown)", providerName: endpoint.name)
        }
        progress("Making the video (\(endpoint.name) job \(id))…")
        let pollURLs = pollAddresses(for: job, startPath: startPath, base: base)
        var pollIndex = 0
        let startedAt = Date()
        while true {
            switch videoState(latest) {
            case .failed(let reason):
                throw OpenRouterAPIError(httpStatus: 502, code: "video_failed", message: "The video didn't get made on \(endpoint.name): \(reason). Nothing is charged for a failed video.", providerName: endpoint.name)
            case .done:
                if let ready = try await finishedVideo(in: latest, base: base, headers: headers, transport: transport) { return ready }
                var seen = Set<String>()
                for path in ([startPath] + startPaths).filter({ seen.insert($0).inserted }) {
                    let download = try await transport.send(HTTPRequest(url: base.appendingPathComponent("\(path)/\(id)/content"), headers: headers, idleTimeout: 300))
                    if download.isSuccess, !download.body.isEmpty, download.headers["content-type"]?.hasPrefix("application/json") != true {
                        return video(from: download, cost: cost(in: latest))
                    }
                }
                throw ToolInputError("\(endpoint.name) finished the video (job \(id)) but didn't give an address to download it from.")
            case .working:
                break
            }
            guard Date().timeIntervalSince(startedAt) < giveUpAfter else {
                throw ToolInputError("The video (\(endpoint.name) job \(id)) was still being made after \(Int(giveUpAfter / 60)) minutes. Pick it up later with video_job \(id); don't start a new one.")
            }
            try await Task.sleep(nanoseconds: UInt64(pollEvery * 1_000_000_000))
            let percent = (latest["progress"]?.intValue).map { " \($0)%" } ?? ""
            progress("Making the video…\(percent) \(Int(Date().timeIntervalSince(startedAt)))s")
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
        let keys = ["request_id", "requestId", "id", "task_id", "taskId", "video_id", "videoId", "job_id", "jobId", "generation_id", "generationId"]
        let places: [JSONValue?] = [job, job["data"], job["output"], job["result"], job["task"], job["data"]?.arrayValue?.first, job["data"]?["task"]]
        for place in places.compactMap({ $0 }) {
            for key in keys {
                if let value = place[key]?.stringValue, !value.isEmpty { return value }
                if let number = place[key]?.intValue { return String(number) }
            }
        }
        return nil
    }

    /// Where to check on the job: an address it gave (same host only), then where it was started,
    /// then the other usual places.
    static func pollAddresses(for job: JSONValue, startPath: String, base: URL) -> [URL] {
        var urls: [URL] = []
        for key in ["polling_url", "status_url", "poll_url", "query_url"] {
            for place in [job, job["data"]].compactMap({ $0 }) {
                if let text = place[key]?.stringValue, let url = sameHost(text, base: base) { urls.append(url) }
            }
        }
        if let id = jobID(in: job) {
            for path in [startPath, "videos/generations", "videos", "video/generations"] {
                urls.append(base.appendingPathComponent("\(path)/\(id)"))
            }
        }
        var seen = Set<URL>()
        return urls.filter { seen.insert($0).inserted }
    }

    /// An https address, or a path on the gateway's own host (OneProvider's `video.url`).
    static func sameHost(_ text: String, base: URL) -> URL? {
        if text.hasPrefix("/"), let url = URL(string: text, relativeTo: base)?.absoluteURL, url.host == base.host { return url }
        if let url = URL(string: text), url.scheme == "https", url.host?.lowercased() == base.host?.lowercased() { return url }
        return nil
    }

    // MARK: Reading a video job

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
    static func videoAddress(in job: JSONValue, base: URL? = nil) -> URL? {
        let candidates: [JSONValue?] = [
            job["video"]?["url"], job["data"]?["video"]?["url"], job["url"], job["video_url"], job["result_url"], job["output"]?["url"], job["output"],
            job["data"]?["url"], job["data"]?["video_url"], job["data"]?["output"], job["data"]?["result_url"],
            job["data"]?.arrayValue?.first?["url"], job["data"]?["data"]?.arrayValue?.first?["url"],
            job["videos"]?.arrayValue?.first?["url"], job["data"]?["videos"]?.arrayValue?.first?["url"],
            job["data"]?["task_result"]?["videos"]?.arrayValue?.first?["url"], job["task_result"]?["videos"]?.arrayValue?.first?["url"],
            job["output"]?["video_url"], job["result"]?["url"], job["result"]?["video_url"], job["data"]?["result"]?["url"],
        ]
        for candidate in candidates {
            guard let text = candidate?.stringValue else { continue }
            if let base, let url = sameHost(text, base: base) { return url }
            if let url = URL(string: text), url.scheme == "https" { return url }
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
        guard videoState(job) == .done, let address = videoAddress(in: job, base: base) else { return nil }
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
