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

    public func redact(_ input: String) -> String {
        var text = input
        // Strip URL userinfo before replacing token substrings, so the harmless repository URL
        // remains readable even when the credential itself matches another rule.
        text = replacing(#"https://[^/@\s]+@((?:www\.)?github\.com/)"#, in: text, template: "https://$1")
        text = exactSecrets.reduce(text) { value, secret in
            value.replacingOccurrences(of: secret, with: Self.marker)
        }
        text = replacing(#"\b(?:github_pat_[A-Za-z0-9_]{20,}|gh[pousr]_[A-Za-z0-9_]{20,}|sk-or-v1-[A-Za-z0-9_-]{16,})\b"#, in: text)
        text = replacing(#"(?i)\bBearer\s+[A-Za-z0-9._~+/=-]{16,}"#, in: text)
        text = replacing(#"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b"#, in: text)
        text = replacing(#"(?i)(access_token|refresh_token|client_secret|code|state)=([^&\s]{8,})"#, in: text, template: "$1=" + Self.marker)
        text = replacing(#"(?s)-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----.*?-----END (?:RSA |EC |OPENSSH )?PRIVATE KEY-----"#, in: text)
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
        let value = try JSONCoding.decoder().decode(JSONValue.self, from: data)
        return try JSONCoding.encoder(pretty: pretty).encode(redact(value))
    }

    private func replacing(_ pattern: String, in text: String, template: String = SensitiveDataRedactor.marker) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return expression.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }
}
