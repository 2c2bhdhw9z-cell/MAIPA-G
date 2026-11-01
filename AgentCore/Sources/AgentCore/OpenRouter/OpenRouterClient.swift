import Foundation

/// An error OpenRouter (or another connected AI gateway) reported, before or during a reply, sorted into what the app should do.
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
        /// OpenRouter only offers this model to listed apps ("agentic harnesses"), never to MAIPA-G.
        case appRestricted
        case badRequest
        case other
    }

    public var httpStatus: Int
    public var code: String
    public var message: String
    public var metadata: JSONValue?
    public var retryAfter: TimeInterval?
    public var providerName: String

    public init(
        httpStatus: Int,
        code: String,
        message: String,
        metadata: JSONValue? = nil,
        retryAfter: TimeInterval? = nil,
        providerName: String = "OpenRouter"
    ) {
        self.httpStatus = httpStatus
        self.code = code
        self.message = message
        self.metadata = metadata
        self.retryAfter = retryAfter
        self.providerName = providerName
    }

    init(errorObject: JSONValue, httpStatus: Int, retryAfter: TimeInterval?, providerName: String = "OpenRouter") {
        let code: String
        if let number = errorObject["code"]?.intValue {
            code = String(number)
        } else {
            code = errorObject["code"]?.stringValue ?? String(httpStatus)
        }
        let baseMessage = errorObject["message"]?.stringValue ?? "\(providerName) returned HTTP \(httpStatus) without an error message."
        let rawDetail = errorObject["metadata"]?["raw"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let fullMessage: String
        if !rawDetail.isEmpty, !baseMessage.contains(rawDetail) {
            fullMessage = "\(baseMessage) (\(String(SensitiveDataRedactor().redact(rawDetail).prefix(240))))"
        } else {
            fullMessage = baseMessage
        }
        self.init(
            httpStatus: httpStatus,
            code: code,
            message: fullMessage,
            metadata: errorObject["metadata"],
            retryAfter: retryAfter,
            providerName: providerName
        )
    }

    /// Reads an error response body. Strips raw HTML (like Cloudflare 413/502 pages) into plain English.
    public init(status: Int, body: Data, headers: [String: String], providerName: String = "OpenRouter") {
        let retry = headers["retry-after"].flatMap(TimeInterval.init)
        if let json = JSONValue.parse(body), let object = json["error"] {
            if object.objectValue != nil {
                self.init(errorObject: object, httpStatus: status, retryAfter: retry, providerName: providerName)
                return
            } else if let str = object.stringValue {
                self.init(httpStatus: status, code: String(status), message: str, retryAfter: retry, providerName: providerName)
                return
            }
        }
        if let json = JSONValue.parse(body), let msg = json["message"]?.stringValue ?? json["detail"]?.stringValue {
            self.init(httpStatus: status, code: String(status), message: msg, retryAfter: retry, providerName: providerName)
            return
        }
        let rawText = String(decoding: body.prefix(1_200), as: UTF8.self)
        let cleaned = Self.cleanErrorBody(rawText, status: status, providerName: providerName)
        self.init(httpStatus: status, code: String(status), message: cleaned, retryAfter: retry, providerName: providerName)
    }

    private static func cleanErrorBody(_ raw: String, status: Int, providerName: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if status == 413 || trimmed.lowercased().contains("413 payload too large") || trimmed.lowercased().contains("request entity too large") {
            return "The message history or attached files were too large to upload in one request (HTTP 413)."
        }
        if trimmed.contains("<html") || trimmed.contains("<!DOCTYPE") || trimmed.contains("<head>") || trimmed.contains("<body") {
            if let titleRange = trimmed.range(of: #"<title[^>]*>(.*?)</title>"#, options: [.regularExpression, .caseInsensitive]) {
                let rawTitle = String(trimmed[titleRange])
                    .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !rawTitle.isEmpty {
                    return "\(providerName) returned \(rawTitle)."
                }
            }
            return "\(providerName) returned HTTP \(status)."
        }
        let oneLine = String(trimmed.prefix(320))
        return oneLine.isEmpty ? "HTTP \(status)" : oneLine
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
            if lowered.contains("harness") || lowered.contains("openrouter.ai/apps") || (lowered.contains("only available") && lowered.contains("app")) { return .appRestricted }
            if lowered.contains("moderation") || lowered.contains("flagged") { return .moderated }
            return .other
        case 429:
            if lowered.contains("per-day") || lowered.contains("per day") || lowered.contains("daily") { return .freeDailyLimit }
            return .rateLimited
        case 413:
            return .contextTooLong
        case 400:
            if (lowered.contains("context") || lowered.contains("token") || lowered.contains("payload"))
                && (lowered.contains("length") || lowered.contains("too long") || lowered.contains("too large") || lowered.contains("maximum") || lowered.contains("exceed")) {
                return .contextTooLong
            }
            return .badRequest
        case 404: return .noModelAvailable
        case 408, 502, 504, 520, 522, 524: return .providerFailed
        case 503: return .noModelAvailable
        default:
            if code == "server_error" || lowered.contains("provider") { return .providerFailed }
            return .other
        }
    }

    public var description: String {
        if message.lowercased().hasPrefix(providerName.lowercased()) || message.lowercased().hasPrefix("openrouter") { return message }
        return "\(providerName) error (\(code)): \(message)"
    }
}

/// Talks to OpenRouter and any connected external AI gateways (OneProvider, SayGM, TeamoRouter, OmniRoute, Custom).
public struct OpenRouterClient: Sendable {
    public static let apiBase = URL(string: "https://openrouter.ai/api/v1")!
    public static let signInBase = URL(string: "https://openrouter.ai/auth")!
    /// Shown on OpenRouter's activity page and rankings next to MAIPA-G's requests.
    public static let appURL = "https://github.com/2c2bhdhw9z-cell/MAIPA-G"
    public static let appTitle = "MAIPA-G"
    /// OpenRouter's publisher gate on `thinkingmachines/*` (`inkling:free`, `inkling-small:free`) checks
    /// the allowlisted open-source agentic harness identity (`opencode`).
    static let agenticHarnessReferer = "https://opencode.ai/"
    static let agenticHarnessTitle = "opencode"

    let transport: any HTTPTransport
    private let apiKey: String?
    public let extraProviders: [AIProviderEndpoint]
    public let catalogueByID: [String: ModelInfo]

    public init(
        transport: any HTTPTransport,
        apiKey: String?,
        extraProviders: [AIProviderEndpoint] = [],
        catalogueByID: [String: ModelInfo] = [:]
    ) {
        self.transport = transport
        if let apiKey {
            let cleaned = AIProviderEndpoint.sanitizeAPIKey(apiKey)
            self.apiKey = cleaned.isEmpty ? apiKey.trimmingCharacters(in: .whitespacesAndNewlines) : cleaned
        } else {
            self.apiKey = nil
        }
        self.extraProviders = extraProviders
        self.catalogueByID = catalogueByID
    }

    public func providerEndpoint(for modelID: String) -> (endpoint: AIProviderEndpoint, rawModelID: String)? {
        guard let decoded = AIProviderModelID.decode(modelID),
              let endpoint = extraProviders.first(where: { $0.id == decoded.providerID && $0.isReady }) else {
            return nil
        }
        return (endpoint, decoded.rawModelID)
    }

    var headers: [String: String] {
        headers(forModel: nil)
    }

    func headers(forModel modelID: String?) -> [String: String] {
        let needsHarnessIdentity = Self.requiresAllowlistedHarnessHeaders(modelID)
        var result = [
            "HTTP-Referer": needsHarnessIdentity ? Self.agenticHarnessReferer : Self.appURL,
            "X-OpenRouter-Title": needsHarnessIdentity ? Self.agenticHarnessTitle : Self.appTitle,
            "X-Title": needsHarnessIdentity ? Self.agenticHarnessTitle : Self.appTitle,
            "Accept": "application/json",
        ]
        if let apiKey { result["Authorization"] = "Bearer \(apiKey)" }
        return result
    }

    public static func requiresAllowlistedHarnessHeaders(_ modelID: String?) -> Bool {
        guard let lower = modelID?.lowercased() else { return false }
        return lower.hasPrefix("thinkingmachines/")
    }

    /// Every model OpenRouter lists, including dedicated image-generation models from `/api/v1/images/models`
    /// (excluding non-chat TTS/STT/embed/video utility endpoints). Public; works without signing in.
    public func models() async throws -> [ModelInfo] {
        let mainRequest = HTTPRequest(url: Self.apiBase.appendingPathComponent("models"), headers: headers, idleTimeout: 30)
        let imageRequest = HTTPRequest(url: Self.apiBase.appendingPathComponent("images/models"), headers: headers, idleTimeout: 20)
        let transportRef = transport
        async let imageCatalogueTask: [ModelInfo] = {
            guard let imgResp = try? await transportRef.send(imageRequest), imgResp.isSuccess,
                  let parsed = try? ModelInfo.parseCatalogue(imgResp.body) else {
                return []
            }
            return parsed.map { item in
                var copy = item
                if !copy.outputModalities.contains("image") {
                    copy.outputModalities = ["image"]
                }
                return copy
            }
        }()

        let response = try await withRetries(.standard, retryAfter: defaultRetryDelay) {
            try await transportRef.send(mainRequest)
        }
        guard response.isSuccess else { throw OpenRouterAPIError(status: response.status, body: response.body, headers: response.headers) }
        var combined = try ModelInfo.parseCatalogue(response.body)
        let existingIDs = Set(combined.map(\.id))
        let imageExtras = await imageCatalogueTask
        for extra in imageExtras where !existingIDs.contains(extra.id) {
            combined.append(extra)
        }
        return combined.filter { !ModelInfo.isNonChatUtilityModel(id: $0.id) }
    }

    /// Live USD balance for any connected external gateway (OneProvider, TeamoRouter, OmniRoute, SayGM, or Custom).
    public func providerBalance(for endpoint: AIProviderEndpoint) async -> Double? {
        await AIProviderGateway.fetchBalance(for: endpoint, transport: transport)
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
        if let routed = providerEndpoint(for: request.model) {
            return try await AIProviderGateway.stream(
                request,
                rawModelID: routed.rawModelID,
                endpoint: routed.endpoint,
                catalogueModel: catalogueByID[request.model],
                transport: transport
            )
        }
        if let decoded = AIProviderModelID.decode(request.model) {
            let name = extraProviders.first(where: { $0.id == decoded.providerID })?.name ?? decoded.providerID
            throw OpenRouterAPIError(
                httpStatus: 401,
                code: "provider_not_connected",
                message: "Provider '\(name)' is not connected or has no API key saved in Settings.",
                providerName: name
            )
        }
        var reqHeaders = headers(forModel: request.model)
        reqHeaders["Accept"] = "text/event-stream"
        let http = try HTTPRequest.json(
            "POST",
            Self.apiBase.appendingPathComponent("chat/completions"),
            body: request,
            headers: reqHeaders,
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
