import Foundation

public struct WebSearchResult: Sendable, Hashable {
    public var title: String
    public var url: URL
    public var snippet: String
}

public struct FreeWebSearch: Sendable {
    let transport: any HTTPTransport
    public init(transport: any HTTPTransport) { self.transport = transport }

    public func search(_ query: String) async throws -> [WebSearchResult] {
        var components = URLComponents(string: "https://html.duckduckgo.com/html/")!
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        let ua = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
        let response = try await transport.send(HTTPRequest(url: components.url!, headers: ["Accept": "text/html,application/xhtml+xml;q=0.9", "User-Agent": ua], idleTimeout: 30))
        if response.status == 202 {
            // DuckDuckGo HTML returns 202 with an empty challenge body under load; try Lite once before failing honestly.
            var lite = URLComponents(string: "https://lite.duckduckgo.com/lite/")!
            lite.queryItems = [URLQueryItem(name: "q", value: query)]
            if let liteResp = try? await transport.send(HTTPRequest(url: lite.url!, headers: ["Accept": "text/html", "User-Agent": ua], idleTimeout: 30)),
               liteResp.status == 200, liteResp.body.count <= WebPageReader.maxBytes {
                let parsed = Self.parse(liteResp.text)
                if !parsed.isEmpty { return parsed }
            }
            throw WebPageError.http(202)
        }
        guard (200..<300).contains(response.status) else { throw WebPageError.http(response.status) }
        guard response.body.count <= WebPageReader.maxBytes else { throw WebPageError.tooLarge }
        return Self.parse(response.text)
    }

    static func parse(_ html: String) -> [WebSearchResult] {
        let primaryPattern = #"(?is)<a[^>]*class=[\"'][^\"']*(?:result__a|result-link)[^\"']*[\"'][^>]*href=[\"']([^\"']+)[\"'][^>]*>(.*?)</a>(.*?)(?=<a[^>]*class=[\"'][^\"']*(?:result__a|result-link)|$)"#
        guard let regex = try? NSRegularExpression(pattern: primaryPattern) else { return [] }
        let matches = regex.matches(in: html, range: NSRange(html.startIndex..., in: html))
        return matches.prefix(10).compactMap { match in
            guard let urlRange = Range(match.range(at: 1), in: html), let titleRange = Range(match.range(at: 2), in: html), let tailRange = Range(match.range(at: 3), in: html) else { return nil }
            var href = WebPageReader.clean(String(html[urlRange]))
            if href.hasPrefix("//") { href = "https:" + href }
            if let components = URLComponents(string: href), components.host?.contains("duckduckgo.com") == true,
               let target = components.queryItems?.first(where: { $0.name == "uddg" })?.value { href = target }
            guard let url = URL(string: href), WebPageReader.isSafe(url) else { return nil }
            let title = WebPageReader.readableText(String(html[titleRange]))
            let snippet = WebPageReader.readableText(String(html[tailRange]))
            return WebSearchResult(title: title, url: url, snippet: String(snippet.prefix(500)))
        }
    }
}

public struct WebSearchTool: AgentTool {
    let searcher: FreeWebSearch
    public let name = "web_search"
    public init(transport: any HTTPTransport) { searcher = FreeWebSearch(transport: transport) }
    public var spec: ToolSpec { ToolSpec(name: name, description: "Search the public web for current information without a paid service.", parameters: ["type": "object", "properties": ["query": ["type": "string"]], "required": ["query"]]) }
    public func runningSummary(for arguments: JSONValue) -> String { "Searching the web for \(Format.quote(arguments.optionalString("query") ?? ""))…" }
    public func run(arguments: JSONValue, progress: @escaping @Sendable (String) -> Void) async throws -> ToolOutput {
        let query = try arguments.requiredString("query"), results = try await searcher.search(query)
        let text = results.enumerated().map { "\($0.offset + 1). \($0.element.title)\n\($0.element.url.absoluteString)\n\($0.element.snippet)" }.joined(separator: "\n\n")
        return ToolOutput(forModel: text.isEmpty ? "No web results found for \(query)." : text, summary: "Searched the web · \(results.count) result\(results.count == 1 ? "" : "s")", detail: text)
    }
}

public struct ReadWebPageTool: AgentTool {
    let reader: WebPageReader
    public let name = "read_web_page"
    public init(transport: any HTTPTransport) { reader = WebPageReader(transport: transport) }
    public var spec: ToolSpec { ToolSpec(name: name, description: "Read the useful text from a public web page.", parameters: ["type": "object", "properties": ["url": ["type": "string"]], "required": ["url"]]) }
    public func runningSummary(for arguments: JSONValue) -> String { "Reading a web page…" }
    public func run(arguments: JSONValue, progress: @escaping @Sendable (String) -> Void) async throws -> ToolOutput {
        let value = try arguments.requiredString("url")
        guard let url = URL(string: value) else { throw ToolInputError("That is not a web address.") }
        let page = try await reader.read(url)
        let output = "Source: \(page.url.absoluteString)\n\(page.title.map { "Title: \($0)\n" } ?? "")\n\(page.text)"
        return ToolOutput(forModel: output, summary: "Read \(page.title ?? page.url.host ?? "web page")", detail: output)
    }
}

public enum OpenRouterWebTools {
    public static let paid: [ToolSpec] = [
        ToolSpec(server: "openrouter:web_search"),
        ToolSpec(server: "openrouter:web_fetch"),
    ]
}
