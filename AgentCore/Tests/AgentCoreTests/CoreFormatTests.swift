import Clibsodium
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

    @Test func buildTwoRecordsAndOldMessagesRoundTrip() throws {
        let old = try JSONCoding.decoder().decode(UserMessage.self, from: Data(#"{"text":"hello"}"#.utf8))
        #expect(old.text == "hello" && old.attachments.isEmpty)

        let attachment = AttachmentReference(name: "photo.jpg", mimeType: "image/jpeg", kind: .image, path: "attachments/id/photo.jpg", bytes: 12)
        let message = UserMessage(text: "look", attachments: [attachment])
        let decodedMessage = try JSONCoding.decoder().decode(UserMessage.self, from: JSONCoding.encoder().encode(message))
        #expect(decodedMessage.text == message.text)
        #expect(decodedMessage.attachments.map(\.id) == message.attachments.map(\.id))

        let memory = MemoryRecord(text: "Use plain words", source: .star)
        let decodedMemory = try JSONCoding.decoder().decode(MemoryRecord.self, from: JSONCoding.encoder().encode(memory))
        #expect(decodedMemory.id == memory.id && decodedMemory.text == memory.text && decodedMemory.source == .star)
        #expect(Chat.currentFormat == 2)
    }

    @Test func creditsCalculateAvailableMoney() {
        let credits = OpenRouterCredits(response: JSONValue.parse(#"{"data":{"total_credits":5,"total_usage":1.25}}"#)!)
        #expect(credits.purchased == 5)
        #expect(credits.used == 1.25)
        #expect(credits.balance == 3.75)
    }

    @Test func githubSecretUsesASealedBox() throws {
        var publicKey = [UInt8](repeating: 0, count: Int(crypto_box_publickeybytes()))
        var secretKey = [UInt8](repeating: 0, count: Int(crypto_box_secretkeybytes()))
        #expect(sodium_init() >= 0)
        #expect(crypto_box_keypair(&publicKey, &secretKey) == 0)
        let encoded = try GitHubSealedBox.encrypt("private-value", publicKeyBase64: Data(publicKey).base64EncodedString())
        let cipher = try #require(Data(base64Encoded: encoded))
        #expect(cipher.count == "private-value".utf8.count + Int(crypto_box_sealbytes()))
        var clear = [UInt8](repeating: 0, count: cipher.count - Int(crypto_box_sealbytes()))
        let opened = cipher.withUnsafeBytes { bytes in
            crypto_box_seal_open(&clear, bytes.bindMemory(to: UInt8.self).baseAddress!, UInt64(cipher.count), &publicKey, &secretKey)
        }
        #expect(opened == 0)
        #expect(String(decoding: clear, as: UTF8.self) == "private-value")
    }

    @Test func oldJobRecordsDecodeAndCheckpointAsRestartableState() async throws {
        let id = UUID()
        let old = Data("""
        {"format":1,"id":"\(id.uuidString)","status":"running","title":"Old job","state":{},"createdAt":"2026-10-28T00:00:00Z","updatedAt":"2026-10-28T00:00:00Z"}
        """.utf8)
        let decoded = try JSONCoding.decoder().decode(JobRecord.self, from: old)
        #expect(decoded.targetRepo == nil)
        #expect(decoded.steps.isEmpty)
        #expect(decoded.cumulativeCost == 0)

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("maipag-jobs-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = JobStore(dataDirectory: root)
        var job = JobRecord(title: "Restart me", targetRepo: RepoRef(owner: "octo", name: "repo"), targetRef: "main", defaultBranch: "main")
        job.steps = [JobStepRecord(title: "First", status: .done)]
        _ = try await store.create(job)
        let stopped = try await store.stop(job.id)
        #expect(stopped.status == .stopped)
        let resumed = try await store.resume(job.id)
        #expect(resumed.status == .queued)
        #expect(resumed.steps.first?.status == .done)
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
