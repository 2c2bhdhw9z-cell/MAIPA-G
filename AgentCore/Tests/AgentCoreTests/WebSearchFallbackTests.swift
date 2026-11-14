import Foundation
import Testing
@testable import AgentCore

private final class HostTransport: HTTPTransport, @unchecked Sendable {
    let handler: @Sendable (HTTPRequest) -> HTTPResponse
    private let lock = NSLock()
    private var seen: [String] = []
    init(_ handler: @escaping @Sendable (HTTPRequest) -> HTTPResponse) { self.handler = handler }
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        lock.withLock { seen.append(request.url.absoluteString) }
        return handler(request)
    }
    func stream(_ request: HTTPRequest) async throws -> HTTPStreamResponse {
        HTTPStreamResponse(status: 500, headers: [:], body: AsyncThrowingStream { $0.finish() })
    }
    var urls: [String] { lock.withLock { seen } }
}

private func html(_ text: String, status: Int = 200) -> HTTPResponse {
    HTTPResponse(status: status, headers: ["content-type": "text/html"], body: Data(text.utf8))
}

@Suite("Web search and page reading find another way")
struct WebSearchFallbackTests {
    static let bingPage = """
    <ol id="b_results"><li class="b_algo" data-id iid=SERP.1><div class="b_tpcn"><a class="tilk" href="https://www.bing.com/ck/a?!&amp;&amp;p=x&amp;u=a1aHR0cHM6Ly9kZXZlbG9wZXIuYXBwbGUuY29tL2RvY3VtZW50YXRpb24vc3dpZnQvYWN0b3I&amp;ntb=1"><div>apple.com</div></a></div>\
    <h2><a target="_blank" href="https://www.bing.com/ck/a?!&amp;&amp;p=x&amp;u=a1aHR0cHM6Ly9kZXZlbG9wZXIuYXBwbGUuY29tL2RvY3VtZW50YXRpb24vc3dpZnQvYWN0b3I&amp;ntb=1" h="ID=SERP"><strong>Actor</strong> | Apple Developer Documentation</a></h2>\
    <div class="b_caption"><p class="b_lineclamp2">The Actor protocol generalizes over all actor types.</p></div></li></ol>
    """

    static let bravePage = """
    <div class="snippet svelte-jmfu5f" data-pos="0" data-type="web" data-keynav="true"><div class="result-body"><a href="https://www.hackingwithswift.com/quick-start/concurrency/what-is-an-actor" target="_self" class="l1">\
    <div class="site-name-content"><cite class="snippet-url">hackingwithswift.com</cite></div><div class="title search-snippet-title line-clamp-1" title="What is an actor">What is an actor and why does Swift have them?</div></a>\
    <div class="generic-snippet"><div class="content desktop-default-regular t-primary">Swift’s actors are like <strong>classes that are safe</strong> in concurrent code.</div></div></div></div>
    """

    @Test("DuckDuckGo refusing (HTTP 202) moves on to Bing, whose links are unwrapped to the real page")
    func refusedSearchTriesTheNextService() async throws {
        let transport = HostTransport { request in
            switch request.url.host {
            case "html.duckduckgo.com": return html("<html>check</html>", status: 202)
            case "www.bing.com": return html(Self.bingPage)
            default: return html("", status: 500)
            }
        }
        let output = try await WebSearchTool(transport: transport).run(arguments: ["query": "swift actor"]) { _ in }
        #expect(output.forModel.contains("https://developer.apple.com/documentation/swift/actor"))
        #expect(output.forModel.contains("Actor | Apple Developer Documentation"))
        #expect(output.forModel.contains("generalizes over all actor types"))
        #expect(transport.urls.count == 2)
    }

    @Test("Brave Search results are read when DuckDuckGo and Bing both refuse")
    func braveIsTheThirdTry() async throws {
        let transport = HostTransport { request in
            request.url.host == "search.brave.com" ? html(Self.bravePage) : html("busy", status: 429)
        }
        let results = try await FreeWebSearch(transport: transport).search("swift actor")
        #expect(results.first?.url.absoluteString == "https://www.hackingwithswift.com/quick-start/concurrency/what-is-an-actor")
        #expect(results.first?.title == "What is an actor and why does Swift have them?")
        #expect(results.first?.snippet.contains("classes that are safe") == true)
    }

    @Test("When every service refuses, the AI is told what each said and what to do instead")
    func everyRefusalIsExplained() async throws {
        let transport = HostTransport { _ in html("no", status: 202) }
        do {
            _ = try await WebSearchTool(transport: transport).run(arguments: ["query": "swift"]) { _ in }
            Issue.record("Expected the search to fail")
        } catch let error as ToolInputError {
            #expect(error.message.contains("DuckDuckGo answered HTTP 202"))
            #expect(error.message.contains("Bing answered HTTP 202"))
            #expect(error.message.contains("read_web_page"))
        }
        #expect(transport.urls.count == FreeWebSearch.Engine.allCases.count)
    }

    @Test("A page that refuses a program (HTTP 403) is read through Jina's reader, never one whose address carries a key")
    func refusedPageGoesThroughTheReader() async throws {
        let transport = HostTransport { request in
            if request.url.host == "r.jina.ai" {
                return HTTPResponse(status: 200, headers: ["content-type": "text/plain"], body: Data("Title: Docs\n\nThe rate limit is 60 a minute.".utf8))
            }
            return html("Forbidden", status: 403)
        }
        let page = try await WebPageReader(transport: transport).read(URL(string: "https://docs.example.com/limits")!)
        #expect(page.text.contains("60 a minute") && page.text.contains("r.jina.ai"))
        #expect(page.url.absoluteString == "https://docs.example.com/limits")
        #expect(transport.urls.last == "https://r.jina.ai/https://docs.example.com/limits")
        await #expect(throws: (any Error).self) {
            _ = try await WebPageReader(transport: transport).read(URL(string: "https://files.example.com/a.zip?X-Amz-Signature=abc")!)
        }
        #expect(!transport.urls.contains { $0.contains("r.jina.ai/https://files.example.com") })
    }

    @Test("Live: the search finds results from this machine", .enabled(if: ProcessInfo.processInfo.environment["MAIPAG_NETWORK_TESTS"] == "1"))
    func liveSearch() async throws {
        let results = try await FreeWebSearch(transport: URLSessionTransport()).search("swift concurrency actors")
        print("LIVE web_search results: \(results.count): \(results.prefix(3).map(\.url.absoluteString))")
        #expect(!results.isEmpty)
        // Each service on its own, so a changed layout shows up here.
        let transport = URLSessionTransport()
        for engine in FreeWebSearch.Engine.allCases {
            let response = try? await transport.send(HTTPRequest(url: engine.url(for: "swift concurrency actors"), headers: FreeWebSearch.headers, idleTimeout: 20))
            print("LIVE \(engine.rawValue): HTTP \(response?.status ?? 0), \(response.map { engine.parse($0.text).count } ?? 0) results")
        }
    }
}
