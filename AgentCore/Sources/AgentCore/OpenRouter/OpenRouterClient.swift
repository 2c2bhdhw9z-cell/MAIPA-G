import Foundation

/// An error OpenRouter reported, before or during a reply, sorted into what the app should do.
public struct OpenRouterAPIError: Error, Sendable, Hashable, CustomStringConvertible {
    public enum Kind: Sendable, Hashable {
        /// The account has no credit left for paid AIs.
        case outOfCredits
        /// Too many paid requests are still settling; wait `retryAfter` and try again.
        case busyRetrySoon
        /// A spending cap on the key or workspace was reached.
        case spendingCapReached
        /// Today's free-AI requests are used up (50 a day under $10 bought, 1,000 above).
        case freeDailyLimit
        /// Too many requests too fast, or the provider is at capacity.
        case rateLimited
        case invalidKey
        case contextTooLong
        case noModelAvailable
        case providerFailed
        case moderated
        case badRequest
        case other
    }

    public var httpStatus: Int
    public var code: String
    public var message: String
    public var metadata: JSONValue?
    public var retryAfter: TimeInterval?

    public init(httpStatus: Int, code: String, message: String, metadata: JSONValue? = nil, retryAfter: TimeInterval? = nil) {
        self.httpStatus = httpStatus
        self.code = code
        self.message = message
        self.metadata = metadata
        self.retryAfter = retryAfter
    }

    init(errorObject: JSONValue, httpStatus: Int, retryAfter: TimeInterval?) {
        let code: String
        if let number = errorObject["code"]?.intValue {
            code = String(number)
        } else {
            code = errorObject["code"]?.stringValue ?? String(httpStatus)
        }
        self.init(
            httpStatus: httpStatus,
            code: code,
            message: errorObject["message"]?.stringValue ?? "Something went wrong at OpenRouter.",
            metadata: errorObject["metadata"],
            retryAfter: retryAfter
        )
    }

    /// Reads an error response body. Falls back to the raw text when it is not OpenRouter's JSON.
    public init(status: Int, body: Data, headers: [String: String]) {
        let retry = headers["retry-after"].flatMap(TimeInterval.init)
        if let json = JSONValue.parse(body), let object = json["error"] {
            self.init(errorObject: object, httpStatus: status, retryAfter: retry)
        } else {
            let text = String(decoding: body.prefix(400), as: UTF8.self)
            self.init(httpStatus: status, code: String(status), message: text.isEmpty ? "HTTP \(status)" : text, retryAfter: retry)
        }
    }

    public var kind: Kind {
        let status = Int(code) ?? httpStatus
        let source = metadata?["limit_source"]?.stringValue ?? ""
        let lowered = message.lowercased()
        switch status {
        case 401: return .invalidKey
        case 402:
            if source == "openrouter_in_flight_budget" { return .busyRetrySoon }
            if source == "openrouter_key_limit" { return .spendingCapReached }
            return .outOfCredits
        case 403:
            if source.contains("budget") || source == "openrouter_key_limit" { return .spendingCapReached }
            if lowered.contains("moderation") || lowered.contains("flagged") { return .moderated }
            return .other
        case 429:
            if lowered.contains("per-day") || lowered.contains("per day") || lowered.contains("daily") { return .freeDailyLimit }
            return .rateLimited
        case 400, 413:
            if lowered.contains("context") && (lowered.contains("length") || lowered.contains("too long") || lowered.contains("maximum")) {
                return .contextTooLong
            }
            return .badRequest
        case 404: return .noModelAvailable
        case 408, 502, 504: return .providerFailed
        case 503: return .noModelAvailable
        default:
            if code == "server_error" || lowered.contains("provider") { return .providerFailed }
            return .other
        }
    }

    public var description: String { "OpenRouter \(code): \(message)" }
}

/// Talks to OpenRouter: the model catalogue, the signed-in key, sign-in, and streamed replies.
public struct OpenRouterClient: Sendable {
    public static let apiBase = URL(string: "https://openrouter.ai/api/v1")!
    public static let signInBase = URL(string: "https://openrouter.ai/auth")!
    /// Shown on OpenRouter's activity page and rankings next to MAIPA-G's requests.
    public static let appURL = "https://github.com/2c2bhdhw9z-cell/MAIPA-G"
    public static let appTitle = "MAIPA-G"

    private let transport: any HTTPTransport
    private let apiKey: String?

    public init(transport: any HTTPTransport, apiKey: String?) {
        self.transport = transport
        self.apiKey = apiKey
    }

    private var headers: [String: String] {
        var headers = [
            "HTTP-Referer": Self.appURL,
            "X-OpenRouter-Title": Self.appTitle,
            "X-Title": Self.appTitle,
            "Accept": "application/json",
        ]
        if let apiKey { headers["Authorization"] = "Bearer \(apiKey)" }
        return headers
    }

    /// Every model OpenRouter lists. Public; works without signing in.
    public func models() async throws -> [ModelInfo] {
        let request = HTTPRequest(url: Self.apiBase.appendingPathComponent("models"), headers: headers, idleTimeout: 30)
        let response = try await withRetries(.standard, retryAfter: defaultRetryDelay) {
            try await transport.send(request)
        }
        guard response.isSuccess else { throw OpenRouterAPIError(status: response.status, body: response.body, headers: response.headers) }
        return try ModelInfo.parseCatalogue(response.body)
    }

    /// Spending, limits and today's free-AI allowance for the signed-in key.
    public func keyInfo() async throws -> OpenRouterKeyInfo {
        let request = HTTPRequest(url: Self.apiBase.appendingPathComponent("key"), headers: headers, idleTimeout: 30)
        let response = try await withRetries(.standard, retryAfter: defaultRetryDelay) {
            try await transport.send(request)
        }
        guard response.isSuccess else { throw OpenRouterAPIError(status: response.status, body: response.body, headers: response.headers) }
        guard let json = JSONValue.parse(response.body) else {
            throw HTTPError.undecodable(status: response.status, type: "key info", detail: "not JSON", body: response.text)
        }
        return OpenRouterKeyInfo(response: json)
    }

    /// Account-wide purchased credit and usage. Some OAuth keys are not allowed to read it.
    public func credits() async throws -> OpenRouterCredits {
        let request = HTTPRequest(url: Self.apiBase.appendingPathComponent("credits"), headers: headers, idleTimeout: 30)
        let response = try await withRetries(.standard, retryAfter: defaultRetryDelay) { try await transport.send(request) }
        guard response.isSuccess else { throw OpenRouterAPIError(status: response.status, body: response.body, headers: response.headers) }
        guard let json = JSONValue.parse(response.body) else { throw HTTPError.undecodable(status: response.status, type: "credits", detail: "not JSON", body: response.text) }
        return OpenRouterCredits(response: json)
    }

    /// Sends a chat request and returns its reply as it streams in. Errors before the reply starts
    /// are thrown here; errors during it arrive as a chunk with `error` set.
    public func stream(_ request: ChatCompletionRequest) async throws -> AsyncThrowingStream<StreamChunk, Error> {
        var headers = headers
        headers["Accept"] = "text/event-stream"
        let http = try HTTPRequest.json(
            "POST",
            Self.apiBase.appendingPathComponent("chat/completions"),
            body: request,
            headers: headers,
            idleTimeout: 180
        )
        let response = try await transport.stream(http)
        guard response.isSuccess else {
            let body = try await response.collect(limit: 64 * 1024)
            throw OpenRouterAPIError(status: response.status, body: body, headers: response.headers)
        }
        let events = response.body.serverSentEvents()
        return AsyncThrowingStream<StreamChunk, Error> { continuation in
            let task = Task {
                do {
                    for try await event in events {
                        if event == "[DONE]" { break }
                        guard let json = JSONValue.parse(event) else { continue }
                        continuation.yield(StreamChunk(json: json))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Sign in (OAuth with PKCE)

    /// The page that asks the user to let MAIPA-G use their OpenRouter account.
    public static func signInURL(callback: URL, pkce: PKCE, state: String, keyLabel: String = "MAIPA-G") -> URL {
        var components = URLComponents(url: signInBase, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "callback_url", value: callback.absoluteString),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "key_label", value: keyLabel),
        ]
        return components.url!
    }

    /// Swaps the code from the sign-in page for an API key that belongs to the user.
    public func exchangeSignInCode(_ code: String, pkce: PKCE) async throws -> String {
        struct Body: Encodable {
            let code: String
            let code_verifier: String
            let code_challenge_method: String
        }
        let request = try HTTPRequest.json(
            "POST",
            Self.apiBase.appendingPathComponent("auth/keys"),
            body: Body(code: code, code_verifier: pkce.verifier, code_challenge_method: "S256"),
            headers: headers.filter { $0.key != "Authorization" },
            idleTimeout: 30
        )
        let response = try await transport.send(request)
        guard response.isSuccess else { throw OpenRouterAPIError(status: response.status, body: response.body, headers: response.headers) }
        guard let key = JSONValue.parse(response.body)?["key"]?.stringValue, !key.isEmpty else {
            throw HTTPError.undecodable(status: response.status, type: "API key", detail: "no key in reply", body: "")
        }
        return key
    }

    /// OpenRouter's page for this key, which only its owner can open.
    public static func keySettingsURL(forKey key: String) -> URL {
        URL(string: "https://openrouter.ai/keys/\(Hashing.sha256Hex(Data(key.utf8)))")!
    }

    public static let creditsURL = URL(string: "https://openrouter.ai/settings/credits")!
}
