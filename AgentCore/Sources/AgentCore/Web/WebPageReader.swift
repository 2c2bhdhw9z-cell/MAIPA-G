import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if os(Linux)
import Glibc
#else
import Darwin
#endif

public enum WebPageError: Error, Sendable, CustomStringConvertible {
    case unsafeURL, unsupportedType(String), tooLarge, http(Int), tooManyRedirects
    public var description: String {
        switch self {
        case .unsafeURL: return "That web address is not safe to open."
        case .unsupportedType(let type): return "That page is \(type), not readable text."
        case .tooLarge: return "That page is too large to read safely."
        case .http(let status): return "The page returned HTTP \(status)."
        case .tooManyRedirects: return "That page redirected too many times."
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
        let response: HTTPResponse
        if transport is URLSessionTransport {
            response = try await SafeWebRequest.send(url, maxBytes: Self.maxBytes)
        } else {
            response = try await transport.send(HTTPRequest(url: url, headers: Self.headers, idleTimeout: 30))
        }
        guard response.isSuccess else { throw WebPageError.http(response.status) }
        let finalURL = response.finalURL ?? url
        guard Self.isSafe(finalURL) else { throw WebPageError.unsafeURL }
        guard response.body.count <= Self.maxBytes else { throw WebPageError.tooLarge }
        let type = response.header("content-type")?.lowercased() ?? "text/html"
        let isReadableType = type.contains("text/")
            || type.contains("html")
            || type.contains("xhtml")
            || type.contains("json")
            || type.contains("xml")
            || type.contains("yaml")
            || type.contains("javascript")
            || type.contains("markdown")
        guard isReadableType else { throw WebPageError.unsupportedType(type) }
        let raw = String(decoding: response.body, as: UTF8.self)
        if type.contains("html") {
            return WebPage(url: finalURL, title: Self.firstMatch(#"<title[^>]*>(.*?)</title>"#, in: raw).map(Self.clean), text: Self.readableText(raw))
        }
        return WebPage(url: finalURL, title: nil, text: String(raw.prefix(200_000)))
    }

    fileprivate static let headers = [
        "Accept": "text/markdown,text/html,text/plain,application/json,application/xml,application/xhtml+xml;q=0.9,*/*;q=0.5",
        "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15 MAIPA-G/1.0",
    ]

    public static func isSafe(_ url: URL) -> Bool {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), let host = url.host?.lowercased(), !host.isEmpty,
              url.user == nil, url.password == nil else { return false }
        if host == "localhost" || host.hasSuffix(".localhost") { return false }
        if let literal = IPAddress.parse(host) { return literal.isPublic }
        return true
    }

    static func readableText(_ html: String) -> String {
        var text = html
        for pattern in [
            #"(?is)<!--.*?-->"#,
            #"(?is)<script\b[^>]*>.*?</script>"#,
            #"(?is)<style\b[^>]*>.*?</style>"#,
            #"(?is)<noscript\b[^>]*>.*?</noscript>"#,
            #"(?is)<template\b[^>]*>.*?</template>"#,
            #"(?is)<iframe\b[^>]*>.*?</iframe>"#,
            #"(?is)<nav\b[^>]*>.*?</nav>"#,
            #"(?is)<footer\b[^>]*>.*?</footer>"#,
            #"(?is)<svg\b[^>]*>.*?</svg>"#,
        ] {
            text = text.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        text = text.replacingOccurrences(of: #"(?i)<br\s*/?>|</p>|</div>|</li>|</h[1-6]>|</section>|</article>|</tr>"#, with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?s)<[^>]+>"#, with: " ", options: .regularExpression)
        text = clean(text)
        let lines = text.components(separatedBy: .newlines).compactMap { rawLine -> String? in
            let line = rawLine.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { return nil }
            // Drop hydrated JSON state / inline telemetry blobs left outside script tags.
            if line.count > 240, (line.hasPrefix("{\"") || line.hasPrefix("[{\"")), (line.hasSuffix("}") || line.hasSuffix("]")) {
                return nil
            }
            return line
        }
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

private enum SafeWebRequest {
    static func send(_ initial: URL, maxBytes: Int) async throws -> HTTPResponse {
        var url = initial
        var resolutions: [String: Set<IPAddress>] = [:]
        for redirect in 0...5 {
            guard WebPageReader.isSafe(url), let host = url.host else { throw WebPageError.unsafeURL }
            let addresses = try IPAddress.resolve(host)
            guard !addresses.isEmpty, addresses.allSatisfy(\.isPublic) else { throw WebPageError.unsafeURL }
            if let prior = resolutions[host.lowercased()], prior != addresses { throw WebPageError.unsafeURL }
            resolutions[host.lowercased()] = addresses

            let delegate = NoRedirectDelegate()
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = 30
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.urlCache = nil
            configuration.httpShouldSetCookies = false
            let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
            defer { session.finishTasksAndInvalidate() }
            var request = URLRequest(url: url)
            request.timeoutInterval = 30
            WebPageReader.headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
            let (data, rawResponse) = try await session.data(for: request)
            guard let response = rawResponse as? HTTPURLResponse else { throw HTTPError.transport("Not an HTTP response", isOffline: false) }
            guard data.count <= maxBytes else { throw WebPageError.tooLarge }
            if (300..<400).contains(response.statusCode), let location = response.value(forHTTPHeaderField: "Location"), let next = URL(string: location, relativeTo: url)?.absoluteURL {
                guard redirect < 5 else { throw WebPageError.tooManyRedirects }
                url = next
                continue
            }
            return HTTPResponse(status: response.statusCode, headers: URLSessionTransport.headers(of: response), body: data, finalURL: url)
        }
        throw WebPageError.tooManyRedirects
    }
}

private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

struct IPAddress: Sendable, Hashable {
    enum Family: Sendable, Hashable { case v4, v6 }
    var family: Family
    var bytes: [UInt8]

    var isPublic: Bool {
        switch family {
        case .v4:
            guard bytes.count == 4 else { return false }
            let a = bytes[0], b = bytes[1]
            if a == 0 || a == 10 || a == 127 || a >= 224 { return false }
            if a == 100 && (64...127).contains(b) { return false }
            if a == 169 && b == 254 { return false }
            if a == 172 && (16...31).contains(b) { return false }
            if a == 192 && (b == 168 || b == 0 || b == 2) { return false }
            if a == 198 && (b == 18 || b == 19 || b == 51) { return false }
            if a == 203 && b == 0 { return false }
            return true
        case .v6:
            guard bytes.count == 16 else { return false }
            if bytes.allSatisfy({ $0 == 0 }) { return false }
            if bytes.dropLast().allSatisfy({ $0 == 0 }) && bytes.last == 1 { return false }
            if bytes[0] & 0xfe == 0xfc || (bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80) || bytes[0] == 0xff { return false }
            if bytes[0] == 0x20 && bytes[1] == 0x01 && bytes[2] == 0x0d && bytes[3] == 0xb8 { return false }
            if bytes.prefix(10).allSatisfy({ $0 == 0 }) && bytes[10] == 0xff && bytes[11] == 0xff {
                return IPAddress(family: .v4, bytes: Array(bytes[12...15])).isPublic
            }
            return true
        }
    }

    static func parse(_ text: String) -> IPAddress? {
        var v4 = in_addr()
        if inet_pton(AF_INET, text, &v4) == 1 {
            return withUnsafeBytes(of: &v4) { IPAddress(family: .v4, bytes: Array($0)) }
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, text, &v6) == 1 {
            return withUnsafeBytes(of: &v6) { IPAddress(family: .v6, bytes: Array($0)) }
        }
        return nil
    }

    static func resolve(_ host: String) throws -> Set<IPAddress> {
        if let literal = parse(host) { return [literal] }
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0 else { throw WebPageError.unsafeURL }
        defer { if let result { freeaddrinfo(result) } }
        var addresses = Set<IPAddress>()
        var cursor = result
        while let current = cursor {
            if current.pointee.ai_family == AF_INET, let address = current.pointee.ai_addr {
                var value = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                addresses.insert(withUnsafeBytes(of: &value) { IPAddress(family: .v4, bytes: Array($0)) })
            } else if current.pointee.ai_family == AF_INET6, let address = current.pointee.ai_addr {
                var value = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }
                addresses.insert(withUnsafeBytes(of: &value) { IPAddress(family: .v6, bytes: Array($0)) })
            }
            cursor = current.pointee.ai_next
        }
        return addresses
    }
}
