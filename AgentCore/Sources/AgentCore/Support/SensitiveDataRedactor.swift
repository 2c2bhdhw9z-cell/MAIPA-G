import Foundation

/// Removes credentials from text before it is written to chats, diagnostics, or logs. Exact
/// runtime secrets can be registered by callers; narrow format patterns provide a final defense
/// for credentials copied into model output or tool records.
public struct SensitiveDataRedactor: Sendable {
    public static let marker = "[REDACTED SECRET]"
    private let exactSecrets: [String]

    public init(secrets: [String] = []) {
        exactSecrets = secrets.filter { !$0.isEmpty }.sorted { $0.count > $1.count }
    }

    /// The patterns, compiled once. Each one used to be compiled again for every string, so a big
    /// chat compiled them hundreds of thousands of times on every save.
    private static let userinfo = compile(#"https://[^/@\s]+@((?:www\.)?github\.com/)"#)
    private static let tokens = compile(#"\b(?:github_pat_[A-Za-z0-9_]{20,}|gh[pousr]_[A-Za-z0-9_]{20,}|sk-or-v1-[A-Za-z0-9_-]{16,}|sk-ant-[A-Za-z0-9_-]{16,}|sk-proj-[A-Za-z0-9_-]{16,}|sk-(?:live|test)_[A-Za-z0-9]{16,}|rk_(?:live|test)_[A-Za-z0-9]{16,}|sk-[A-Za-z0-9]{24,}|xox[baprs]-[A-Za-z0-9-]{16,}|ntn_[A-Za-z0-9]{16,}|secret_[A-Za-z0-9]{20,}|figd_[A-Za-z0-9_-]{16,}|sbp_[A-Za-z0-9]{20,}|glpat-[A-Za-z0-9_-]{16,}|shpat_[A-Za-z0-9]{16,}|pplx-[A-Za-z0-9]{20,}|tvly-[A-Za-z0-9_-]{16,}|BSA[A-Za-z0-9]{16,}|AIza[0-9A-Za-z_-]{30,})\b"#)
    private static let bearer = compile(#"(?i)\bBearer\s+[A-Za-z0-9._~+/=-]{16,}"#)
    private static let jwt = compile(#"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b"#)
    /// OAuth values. `code` and `state` count only in an address (after ?, & or #): plain code such
    /// as `nCode=be(cd,24,4)` or `transitionState=…` used to be "redacted". The value may not be
    /// the marker itself: it matched its own "[REDACTED" and grew " SECRET]" on every save, so the
    /// quick no-change check never passed and every load and save of a big chat took seconds
    /// (owner, 16 November 2026: opening a chat took about 30 seconds).
    private static let oauth = compile(#"(?i)(\b(?:access_token|refresh_token|client_secret)|[?&#](?:code|state))=(?!\[REDACTED)([^&\s"'\\<>]{8,})"#)
    private static let privateKey = compile(#"(?s)-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----.*?-----END (?:RSA |EC |OPENSSH )?PRIVATE KEY-----"#)
    /// "[REDACTED SECRET] SECRET] SECRET]…", left by the old OAuth rule: back to one marker.
    private static let repeatedMarker = compile(#"\[REDACTED SECRET\](?: SECRET\])+"#)

    private static func compile(_ pattern: String) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: pattern)
    }

    public func redact(_ input: String) -> String {
        var text = Self.replacing(Self.repeatedMarker, in: input)
        // Strip URL userinfo before replacing token substrings, so the harmless repository URL
        // remains readable even when the credential itself matches another rule.
        text = Self.replacing(Self.userinfo, in: text, template: "https://$1")
        text = exactSecrets.reduce(text) { value, secret in
            value.replacingOccurrences(of: secret, with: Self.marker)
        }
        text = Self.replacing(Self.tokens, in: text)
        text = Self.replacing(Self.bearer, in: text)
        text = Self.replacing(Self.jwt, in: text)
        text = Self.replacing(Self.oauth, in: text, template: "$1=" + Self.marker)
        text = Self.replacing(Self.privateKey, in: text)
        return text
    }

    public func redact(_ value: JSONValue) -> JSONValue {
        switch value {
        case .string(let text): return .string(redact(text))
        case .array(let values): return .array(values.map(redact))
        case .object(let object): return .object(object.mapValues(redact))
        case .null, .bool, .number: return value
        }
    }

    public func redactCodable<T: Codable>(_ value: T) throws -> T {
        let encoded = try JSONCoding.encoder().encode(value)
        let redacted = try redactJSON(encoded, pretty: false)
        return try JSONCoding.decoder().decode(T.self, from: redacted)
    }

    public func redactJSON(_ data: Data, pretty: Bool = true) throws -> Data {
        if let rawText = String(data: data, encoding: .utf8), redact(rawText) == rawText {
            // Preserve byte-for-byte representation when nothing in the JSON matched a secret,
            // preventing download/upload hash churn across devices.
            return data
        }
        let value = try JSONCoding.decoder().decode(JSONValue.self, from: data)
        return try JSONCoding.encoder(pretty: pretty).encode(redact(value))
    }

    private static func replacing(_ expression: NSRegularExpression?, in text: String, template: String = SensitiveDataRedactor.marker) -> String {
        guard let expression else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        // Nothing to replace (nearly always): the text is returned as it is, not copied.
        guard expression.firstMatch(in: text, range: range) != nil else { return text }
        return expression.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }
}
