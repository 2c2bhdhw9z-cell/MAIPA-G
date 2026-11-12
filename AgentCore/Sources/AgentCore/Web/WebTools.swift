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
        let results = Self.parse(response.text)
        // An empty list means "nothing found" only when the page says so; otherwise the page
        // wasn't one MAIPA-G could read (a check page, or a changed layout).
        if results.isEmpty, !Self.saysNoResults(response.text) { throw WebSearchError.unreadableResults }
        return results
    }

    /// DuckDuckGo's own "No results." page (HTML and Lite).
    static func saysNoResults(_ html: String) -> Bool {
        let lower = html.lowercased()
        return lower.contains("class=\"no-results") || lower.contains("no results.") || lower.contains("no results found")
            || lower.contains("did not match any")
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

public enum WebSearchError: Error, Sendable, Equatable, CustomStringConvertible, LocalizedError {
    /// The search service answered, but not with a results page MAIPA-G could read.
    case unreadableResults
    case queryTooLong(Int)

    public var description: String {
        switch self {
        case .unreadableResults:
            return "The search ran, but its results page couldn't be read (the search service may have shown a check page or changed its layout). This is not \"no results\": try again in a moment or with different words."
        case .queryTooLong(let count):
            return "The search query is \(count) characters; keep it to \(WebSearchTool.maxQueryCharacters) or fewer. Use the few words that matter most."
        }
    }

    public var errorDescription: String? { description }
}

public struct WebSearchTool: AgentTool {
    let searcher: FreeWebSearch
    public let name = "web_search"
    public static let maxQueryCharacters = 200
    public init(transport: any HTTPTransport) { searcher = FreeWebSearch(transport: transport) }
    public var spec: ToolSpec {
        ToolSpec(
            name: name,
            description: """
            Search the public web and get up to 10 results, each with its title, address and a short snippet. Use it for current \
            facts, prices, versions, release notes, docs and anything that may have changed, rather than guessing; then read the \
            best pages with read_web_page. Keep the query short and specific: at most 200 characters (a longer one is refused). \
            "No web results" means the search ran and found nothing; when the results page couldn't be read, the call fails and \
            says so, which is worth retrying. Don't use it for something in the repo (use search_code) or on the computer.
            """,
            parameters: [
                "type": "object",
                "properties": ["query": ["type": "string", "description": "What to search for, at most 200 characters, like \"swift 6 strict concurrency Sendable closure\"."]],
                "required": ["query"],
            ]
        )
    }
    public func runningSummary(for arguments: JSONValue) -> String { "Searching the web for \(Format.quote(arguments.optionalString("query") ?? ""))…" }
    public func run(arguments: JSONValue, progress: @escaping @Sendable (String) -> Void) async throws -> ToolOutput {
        let query = try arguments.requiredString("query").trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count <= Self.maxQueryCharacters else { throw ToolInputError(WebSearchError.queryTooLong(query.count).description) }
        let results = try await searcher.search(query)
        let text = results.enumerated().map { "\($0.offset + 1). \($0.element.title)\n\($0.element.url.absoluteString)\n\($0.element.snippet)" }.joined(separator: "\n\n")
        return ToolOutput(forModel: text.isEmpty ? "No web results found for \(query). The search ran and found nothing; try other words." : text, summary: "Searched the web · \(results.count) result\(results.count == 1 ? "" : "s")", detail: text)
    }
}

public struct ReadWebPageTool: AgentTool {
    let reader: WebPageReader
    public let name = "read_web_page"
    /// What mode "truncated" (the default) returns, like Kiro's web fetch.
    public static let truncatedCharacters = 30_000
    public init(transport: any HTTPTransport) { reader = WebPageReader(transport: transport) }
    public var spec: ToolSpec {
        ToolSpec(
            name: name,
            description: """
            Read a public web page (http or https) and get its readable text: headings, paragraphs, lists and tables, without \
            scripts, menus or footers. JSON, XML, Markdown and plain-text addresses are read as they are. Use it for docs, articles, \
            READMEs, changelogs and API answers, usually after web_search. mode "truncated" (the default) returns the first 30,000 \
            characters; "full" returns the whole text (up to 200,000 characters); "selective" returns only the parts that mention \
            search_phrase, with a few lines around each. The result always says when text was left out and how to get it. \
            Private and local addresses are refused, pages over 2 MB aren't read, and it can't sign in, run JavaScript or fill in forms. \
            Don't use it to search (use web_search first) or for files in the repo (use read_file).
            """,
            parameters: [
                "type": "object",
                "properties": [
                    "url": ["type": "string", "description": "The full address, starting with https:// or http://."],
                    "mode": ["type": "string", "enum": ["truncated", "full", "selective"], "description": "truncated (default): the first 30,000 characters. full: the whole page. selective: only the parts that mention search_phrase."],
                    "search_phrase": ["type": "string", "description": "For mode selective: the word or phrase to find, like \"rate limit\"."],
                ],
                "required": ["url"],
            ]
        )
    }
    public func runningSummary(for arguments: JSONValue) -> String { "Reading a web page…" }
    public func run(arguments: JSONValue, progress: @escaping @Sendable (String) -> Void) async throws -> ToolOutput {
        let value = try arguments.requiredString("url")
        guard let url = URL(string: value) else { throw ToolInputError("That is not a web address.") }
        let phrase = arguments.optionalString("search_phrase")
        let mode = arguments.optionalString("mode")?.lowercased() ?? (phrase != nil ? "selective" : "truncated")
        guard ["truncated", "full", "selective"].contains(mode) else {
            throw ToolInputError("mode must be \"truncated\", \"full\" or \"selective\".")
        }
        if mode == "selective", phrase == nil {
            throw ToolInputError("mode \"selective\" needs search_phrase: the word or phrase to find on the page.")
        }
        let page = try await reader.read(url)
        let header = "Source: \(page.url.absoluteString)\n\(page.title.map { "Title: \($0)\n" } ?? "")\n"
        let body = Self.body(of: page, mode: mode, phrase: phrase)
        let output = header + body
        return ToolOutput(forModel: output, summary: "Read \(page.title ?? page.url.host ?? "web page")", detail: output)
    }

    static func body(of page: WebPage, mode: String, phrase: String?) -> String {
        let total = max(page.totalCharacters, page.text.count)
        switch mode {
        case "full":
            guard page.wasCut else { return page.text }
            return page.text + "\n\n[The page's text stops here: \(page.text.count) of its \(total) characters were read. Use mode \"selective\" with search_phrase to find a later part.]"
        case "selective":
            let found = selectiveSections(page.text, phrase: phrase ?? "")
            guard !found.sections.isEmpty else {
                return "[No part of the page mentions “\(phrase ?? "")”. The page has \(total) characters of text: read it with mode \"truncated\" or \"full\", or try another phrase.]"
            }
            var text = "[Only the parts of the page that mention “\(phrase ?? "")”: \(found.matches) matching line\(found.matches == 1 ? "" : "s") in \(found.sections.count) part\(found.sections.count == 1 ? "" : "s") of a \(total)-character page.\(found.matches > found.shownMatches ? " The first \(found.shownMatches) are shown." : "")]\n\n"
            text += found.sections.joined(separator: "\n\n…\n\n")
            return text
        default:
            guard page.text.count > truncatedCharacters else { return page.text }
            return String(page.text.prefix(truncatedCharacters)) + "\n\n[Showing the first \(truncatedCharacters) of \(total) characters. Pass mode \"full\" for the whole page, or mode \"selective\" with search_phrase for only the parts about something.]"
        }
    }

    /// The lines that mention `phrase` (ignoring case and accents), each with `context` lines
    /// around it, joined where they overlap. When no line has the whole phrase, lines with every
    /// one of its words count.
    static func selectiveSections(_ text: String, phrase: String, context: Int = 3, maxMatches: Int = 40) -> (sections: [String], matches: Int, shownMatches: Int) {
        let needle = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return ([], 0, 0) }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        var hits = lines.indices.filter { lines[$0].range(of: needle, options: options) != nil }
        if hits.isEmpty {
            let words = needle.split(whereSeparator: { $0.isWhitespace }).map(String.init).filter { $0.count > 1 }
            if words.count > 1 {
                hits = lines.indices.filter { index in words.allSatisfy { lines[index].range(of: $0, options: options) != nil } }
            }
        }
        let shown = Array(hits.prefix(maxMatches))
        var ranges: [ClosedRange<Int>] = []
        for hit in shown {
            let range = max(0, hit - context)...min(lines.count - 1, hit + context)
            if let last = ranges.last, range.lowerBound <= last.upperBound + 1 {
                ranges[ranges.count - 1] = last.lowerBound...max(last.upperBound, range.upperBound)
            } else {
                ranges.append(range)
            }
        }
        let sections = ranges.map { lines[$0].joined(separator: "\n") }
        return (sections, hits.count, shown.count)
    }
}

public enum OpenRouterWebTools {
    public static let paid: [ToolSpec] = [
        ToolSpec(server: "openrouter:web_search"),
        ToolSpec(server: "openrouter:web_fetch"),
    ]
}
