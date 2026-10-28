import Foundation
import Testing
@testable import AgentCore

@Suite("JSON and hashing")
struct CoreFormatTests {
    @Test func jsonRoundTripKeepsIntegersWhole() throws {
        let value: JSONValue = ["id": 12, "price": 0.5, "name": "x", "ok": true, "none": nil, "list": [1, "two"]]
        let text = value.jsonString()
        #expect(text == #"{"id":12,"list":[1,"two"],"name":"x","none":null,"ok":true,"price":0.5}"#)
        #expect(JSONValue.parse(text) == value)
    }

    @Test func numbersAreNotMistakenForBooleans() {
        #expect(JSONValue.parse("1") == .number(1))
        #expect(JSONValue.parse("true") == .bool(true))
        #expect(JSONValue.parse(#"{"a":0}"#)?["a"]?.intValue == 0)
    }

    @Test func datesRoundTripWithMilliseconds() throws {
        struct Box: Codable, Equatable { var date: Date }
        let box = Box(date: Date(timeIntervalSince1970: 1_761_700_000.123))
        let data = try JSONCoding.encoder().encode(box)
        let decoded = try JSONCoding.decoder().decode(Box.self, from: data)
        #expect(abs(decoded.date.timeIntervalSince1970 - box.date.timeIntervalSince1970) < 0.001)
        // GitHub's whole-second dates read too.
        let github = try JSONCoding.decoder().decode(Box.self, from: Data(#"{"date":"2026-10-28T03:55:00Z"}"#.utf8))
        #expect(github.date.timeIntervalSince1970 == 1_793_159_700)
    }

    @Test func gitBlobIDMatchesGit() {
        // `printf 'hello\n' | git hash-object --stdin`
        #expect(Hashing.gitBlobID(Data("hello\n".utf8)) == "ce013625030ba8dba906f756967f9e9ca394464a")
        // The empty file.
        #expect(Hashing.gitBlobID(Data()) == "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391")
    }

    @Test func pkceMatchesTheRFCExample() {
        // Checked with Python: base64url(sha256(verifier)) without padding.
        let pkce = PKCE(verifier: "dBjftJeZ4CVP-mJ92K9rIn2ky-qD9-kOaeH-SiUpY4U")
        #expect(pkce.challenge == "kCqRomV8XVt03HEMnNlTFGGgqKZAmQrX40se9cONvl8")
        #expect(PKCE().verifier.count == 43)
    }

    @Test func base64URLRoundTrips() {
        let data = Data([0xfb, 0xff, 0xfe, 0x00, 0x10])
        let encoded = Base64URL.encode(data)
        #expect(!encoded.contains("+") && !encoded.contains("/") && !encoded.contains("="))
        #expect(Base64URL.decode(encoded) == data)
    }
}

@Suite("Server-sent events")
struct ServerSentEventTests {
    @Test func splitsEventsAcrossArbitraryChunks() {
        let stream = ": OPENROUTER PROCESSING\n\ndata: {\"a\":1}\n\ndata: {\"b\":\r\ndata: 2}\r\n\r\ndata: [DONE]\n\n"
        let bytes = Array(stream.utf8)
        for size in [1, 2, 3, 7, 64] {
            var parser = ServerSentEventParser()
            var events: [String] = []
            var index = 0
            while index < bytes.count {
                let end = min(index + size, bytes.count)
                events += parser.feed(Data(bytes[index..<end]))
                index = end
            }
            events += parser.finish()
            #expect(events == ["{\"a\":1}", "{\"b\":\n2}", "[DONE]"], "chunk size \(size)")
        }
    }

    @Test func keepsMultiByteCharactersWhole() {
        let text = "data: héllo 👋\n\n"
        var parser = ServerSentEventParser()
        var events: [String] = []
        for byte in text.utf8 { events += parser.feed(Data([byte])) }
        #expect(events == ["héllo 👋"])
    }

    @Test func finalEventWithoutBlankLineCounts() {
        var parser = ServerSentEventParser()
        #expect(parser.feed(Data("data: last".utf8)).isEmpty)
        #expect(parser.finish() == ["last"])
    }
}

@Suite("Glob patterns")
struct GlobTests {
    @Test(arguments: [
        ("*.swift", "App/Sources/Main.swift", true),
        ("*.swift", "README.md", false),
        ("App/**/*.swift", "App/Sources/Deep/Main.swift", true),
        ("App/**/*.swift", "App/Main.swift", true),
        ("App/*.swift", "App/Sources/Main.swift", false),
        ("**/test_*.py", "a/b/test_x.py", true),
        ("{App,Tests}/**", "Tests/x/y.txt", true),
        ("{App,Tests}/**", "Docs/x.txt", false),
        ("src/[a-c]*.ts", "src/beta.ts", true),
        ("src/[!a-c]*.ts", "src/beta.ts", false),
        ("?.md", "a.md", true),
        ("docs/**", "docs/index.html", true),
        ("*.{png,jpg}", "assets/logo.png", true),
    ])
    func matches(pattern: String, path: String, expected: Bool) {
        #expect(Glob(pattern).matches(path) == expected)
    }
}
