import Foundation

public struct WebSearchResult: Sendable, Hashable {
    public var title: String
    public var url: URL
    public var snippet: String
}

public struct FreeWebSearch: Sendable {
    let transport: any HTTPTransport
    public init(transport: any HTTPTransport) { self.transport = transport }

    /// The search services tried, in order. Each answers people, not programs, and refuses an
    /// automated search now and then (DuckDuckGo answers HTTP 202 with a check page, and did for
    /// 4 searches out of 4 from the chat computer on 13 November 2026), so a refusal moves on to
    /// the next one instead of failing the search.
    enum Engine: String, CaseIterable, Sendable {
        case duckDuckGo = "DuckDuckGo"
        case bing = "Bing"
        case brave = "Brave Search"
        case duckDuckGoLite = "DuckDuckGo Lite"

        func url(for query: String) -> URL {
            var components: URLComponents
            switch self {
            case .duckDuckGo:
                components = URLComponents(string: "https://html.duckduckgo.com/html/")!
                components.queryItems = [URLQueryItem(name: "q", value: query)]
            case .bing:
                components = URLComponents(string: "https://www.bing.com/search")!
                components.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "setlang", value: "en"), URLQueryItem(name: "cc", value: "US")]
            case .brave:
                components = URLComponents(string: "https://search.brave.com/search")!
                components.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "source", value: "web")]
            case .duckDuckGoLite:
                components = URLComponents(string: "https://lite.duckduckgo.com/lite/")!
                components.queryItems = [URLQueryItem(name: "q", value: query)]
            }
            return components.url!
        }

        func parse(_ html: String) -> [WebSearchResult] {
            switch self {
            case .duckDuckGo, .duckDuckGoLite: FreeWebSearch.parse(html)
            case .bing: FreeWebSearch.parseBing(html)
            case .brave: FreeWebSearch.parseBrave(html)
            }
        }

        func saysNoResults(_ html: String) -> Bool {
            switch self {
            case .duckDuckGo, .duckDuckGoLite: FreeWebSearch.saysNoResults(html)
            case .bing: html.contains("class=\"b_no\"") || html.lowercased().contains("there are no results for")
            case .brave: html.lowercased().contains("not many great matches") || html.lowercased().contains("no results found")
            }
        }
    }

    static let headers = [
        "Accept": "text/html,application/xhtml+xml;q=0.9,*/*;q=0.8",
        "Accept-Language": "en-US,en;q=0.9",
        "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15",
    ]

    public func search(_ query: String) async throws -> [WebSearchResult] {
        var refusals: [String] = []
        var allUnreadable = true
        for engine in Engine.allCases {
            try Task.checkCancellation()
            let response: HTTPResponse
            do {
                response = try await transport.send(HTTPRequest(url: engine.url(for: query), headers: Self.headers, idleTimeout: 20))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                allUnreadable = false
                refusals.append("\(engine.rawValue) couldn't be reached (\(ErrorExplainer.describe(error).message))")
                continue
            }
            guard response.status == 200 else {
                allUnreadable = false
                refusals.append("\(engine.rawValue) answered HTTP \(response.status)\(response.status == 202 ? " (it refuses automated searches for a while)" : "")")
                continue
            }
            guard response.body.count <= WebPageReader.maxBytes else {
                refusals.append("\(engine.rawValue) sent a page too big to read")
                continue
            }
            let html = response.text
            let results = engine.parse(html)
            if !results.isEmpty { return results }
            // An empty list means "nothing found" only when the page says so; otherwise the page
            // wasn't one MAIPA-G could read (a check page, or a changed layout).
            if engine.saysNoResults(html) { return [] }
            refusals.append("\(engine.rawValue) sent a page with no readable results (a check page or a new layout)")
        }
        if allUnreadable { throw WebSearchError.unreadableResults }
        throw WebSearchError.everyServiceRefused(refusals)
    }

    /// Bing: each result is an `li.b_algo` with the link in its heading (through Bing's own
    /// address, which carries the real one base64-encoded after `u=a1`) and the snippet in a `p`.
    static func parseBing(_ html: String) -> [WebSearchResult] {
        guard let block = try? NSRegularExpression(pattern: #"(?is)<li class="b_algo"(.*?)</li>"#),
              let heading = try? NSRegularExpression(pattern: #"(?is)<h2[^>]*>\s*<a[^>]*href="([^"]+)"[^>]*>(.*?)</a>"#),
              let paragraph = try? NSRegularExpression(pattern: #"(?is)<p[^>]*>(.*?)</p>"#) else { return [] }
        var results: [WebSearchResult] = []
        for match in block.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            guard results.count < 10, let range = Range(match.range(at: 1), in: html) else { continue }
            let item = String(html[range])
            let whole = NSRange(item.startIndex..., in: item)
            guard let link = heading.firstMatch(in: item, range: whole),
                  let hrefRange = Range(link.range(at: 1), in: item), let titleRange = Range(link.range(at: 2), in: item) else { continue }
            guard let url = bingTarget(WebPageReader.clean(String(item[hrefRange]))), WebPageReader.isSafe(url) else { continue }
            var snippet = ""
            if let text = paragraph.firstMatch(in: item, range: whole), let textRange = Range(text.range(at: 1), in: item) {
                snippet = WebPageReader.readableText(String(item[textRange]))
            }
            results.append(WebSearchResult(title: WebPageReader.readableText(String(item[titleRange])), url: url, snippet: String(snippet.prefix(500))))
        }
        return results
    }

    static func bingTarget(_ href: String) -> URL? {
        guard let components = URLComponents(string: href) else { return nil }
        if components.host?.hasSuffix("bing.com") == true, components.path.hasPrefix("/ck/") {
            guard let encoded = components.queryItems?.first(where: { $0.name == "u" })?.value, encoded.hasPrefix("a1") else { return nil }
            var base64 = String(encoded.dropFirst(2)).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            while base64.count % 4 != 0 { base64 += "=" }
            guard let data = Data(base64Encoded: base64), let target = String(data: data, encoding: .utf8) else { return nil }
            return URL(string: target)
        }
        return URL(string: href)
    }

    /// Brave Search: each web result is a `div.snippet` with `data-type="web"`; its first link is
    /// the page, the title is in `.title`, the snippet in `.content`.
    static func parseBrave(_ html: String) -> [WebSearchResult] {
        guard let link = try? NSRegularExpression(pattern: #"(?is)<a[^>]*href="(https?://[^"]+)""#),
              let title = try? NSRegularExpression(pattern: #"(?is)<div class="title[^"]*"[^>]*>(.*?)</div>"#),
              let content = try? NSRegularExpression(pattern: #"(?is)<div class="content[^"]*"[^>]*>(.*?)</div>"#) else { return [] }
        var results: [WebSearchResult] = []
        for piece in html.components(separatedBy: #"data-type="web""#).dropFirst() {
            guard results.count < 10 else { break }
            let item = String(piece.prefix(12_000))
            let whole = NSRange(item.startIndex..., in: item)
            guard let found = link.firstMatch(in: item, range: whole), let hrefRange = Range(found.range(at: 1), in: item),
                  let url = URL(string: WebPageReader.clean(String(item[hrefRange]))), WebPageReader.isSafe(url),
                  url.host?.hasSuffix("brave.com") != true else { continue }
            var name = ""
            if let match = title.firstMatch(in: item, range: whole), let range = Range(match.range(at: 1), in: item) {
                name = WebPageReader.readableText(String(item[range]))
            }
            var snippet = ""
            if let match = content.firstMatch(in: item, range: whole), let range = Range(match.range(at: 1), in: item) {
                snippet = WebPageReader.readableText(String(item[range]))
            }
            guard !name.isEmpty else { continue }
            results.append(WebSearchResult(title: name, url: url, snippet: String(snippet.prefix(500))))
        }
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
    /// Every search service was tried and none gave results; what each one said.
    case everyServiceRefused([String])

    public var description: String {
        switch self {
        case .unreadableResults:
            return "The search ran, but its results page couldn't be read (the search service may have shown a check page or changed its layout). This is not \"no results\": try again in a moment or with different words."
        case .everyServiceRefused(let reasons):
            return "No search service gave results this time: \(reasons.joined(separator: "; ")). This is not \"no results\". Try again in a minute, or read a page you know directly with read_web_page (for example the project's docs or GitHub page), or search from the computer with run_command and curl."
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
        let results: [WebSearchResult]
        do {
            results = try await searcher.search(query)
        } catch WebSearchError.everyServiceRefused(let reasons) {
            // Said as it is: a generic "try again" hid which services refused and what to do instead.
            throw ToolInputError(WebSearchError.everyServiceRefused(reasons).description)
        }
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
