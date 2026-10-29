import Foundation

public enum WebPageError: Error, Sendable, CustomStringConvertible {
    case unsafeURL, unsupportedType(String), tooLarge, http(Int)
    public var description: String {
        switch self {
        case .unsafeURL: return "That web address is not safe to open."
        case .unsupportedType(let type): return "That page is \(type), not readable text."
        case .tooLarge: return "That page is too large to read safely."
        case .http(let status): return "The page returned HTTP \(status)."
        }
    }
}

public struct WebPage: Sendable, Hashable {
    public var url: URL
    public var title: String?
    public var text: String
}

public struct WebPageReader: Sendable {
    public static let maxBytes = 2_000_000
    let transport: any HTTPTransport
    public init(transport: any HTTPTransport) { self.transport = transport }

    public func read(_ url: URL) async throws -> WebPage {
        guard Self.isSafe(url) else { throw WebPageError.unsafeURL }
        let response = try await transport.send(HTTPRequest(url: url, headers: ["Accept": "text/html,text/plain,application/xhtml+xml;q=0.9", "User-Agent": "MAIPA-G/1.0"], idleTimeout: 30))
        guard response.isSuccess else { throw WebPageError.http(response.status) }
        let finalURL = response.finalURL ?? url
        guard Self.isSafe(finalURL) else { throw WebPageError.unsafeURL }
        guard response.body.count <= Self.maxBytes else { throw WebPageError.tooLarge }
        let type = response.header("content-type")?.lowercased() ?? "text/html"
        guard type.contains("text/") || type.contains("html") || type.contains("xhtml") else { throw WebPageError.unsupportedType(type) }
        let raw = String(decoding: response.body, as: UTF8.self)
        if type.contains("html") {
            return WebPage(url: finalURL, title: Self.firstMatch(#"<title[^>]*>(.*?)</title>"#, in: raw).map(Self.clean), text: Self.readableText(raw))
        }
        return WebPage(url: finalURL, title: nil, text: String(raw.prefix(200_000)))
    }

    public static func isSafe(_ url: URL) -> Bool {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), let host = url.host?.lowercased(), !host.isEmpty else { return false }
        if host == "localhost" || host.hasSuffix(".localhost") || host == "0.0.0.0" || host == "::1" { return false }
        let privatePrefixes = ["10.", "127.", "169.254.", "192.168."]
        if privatePrefixes.contains(where: host.hasPrefix) { return false }
        if host.hasPrefix("172."), let second = host.split(separator: ".").dropFirst().first.flatMap({ Int($0) }), (16...31).contains(second) { return false }
        return true
    }

    static func readableText(_ html: String) -> String {
        var text = html
        for pattern in [#"(?is)<script\b[^>]*>.*?</script>"#, #"(?is)<style\b[^>]*>.*?</style>"#, #"(?is)<nav\b[^>]*>.*?</nav>"#, #"(?is)<svg\b[^>]*>.*?</svg>"#] {
            text = text.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        text = text.replacingOccurrences(of: #"(?i)<br\s*/?>|</p>|</div>|</li>|</h[1-6]>"#, with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?s)<[^>]+>"#, with: " ", options: .regularExpression)
        text = clean(text)
        let lines = text.components(separatedBy: .newlines).map { $0.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return String(lines.joined(separator: "\n").prefix(200_000))
    }

    static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#39;", with: "'").replacingOccurrences(of: "&nbsp;", with: " ")
    }

    static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern), let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}
