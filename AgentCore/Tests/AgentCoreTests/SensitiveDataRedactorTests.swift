import Foundation
import Testing
@testable import AgentCore

@Suite("Saved-chat secret redaction")
struct SensitiveDataRedactorTests {
    @Test func redactsKnownCredentialShapesWithoutDestroyingRepoURLsOrSHAs() {
        let github = "ghs_abcdefghijklmnopqrstuvwxyz123456"
        let openRouter = "sk-or-v1-abcdefghijklmnopqrstuvwxyz123456"
        let sha = "0123456789abcdef0123456789abcdef01234567"
        let input = "Bearer \(github) \(openRouter) https://x-access-token:\(github)@github.com/acme/private.git \(sha)"
        let result = SensitiveDataRedactor().redact(input)

        #expect(!result.contains(github))
        #expect(!result.contains(openRouter))
        #expect(result.contains("https://github.com/acme/private.git"))
        #expect(result.contains(sha))
    }

    @Test func exactOpaqueSecretsAndNestedJSONAreRedacted() {
        let redactor = SensitiveDataRedactor(secrets: ["opaque value with spaces"])
        let value: JSONValue = ["outer": ["opaque value with spaces", ["token": "github_pat_abcdefghijklmnopqrstuvwxyz123456"]]]
        let output = redactor.redact(value).jsonString()

        #expect(!output.contains("opaque value with spaces"))
        #expect(!output.contains("github_pat_"))
    }

    @Test func chatStoreNeverWritesOrReloadsASecret() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("maipag-redaction-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ChatStore(dataDirectory: root)
        let secret = "ghs_abcdefghijklmnopqrstuvwxyz123456"
        var chat = Chat(title: "Private")
        chat.messages = [.user("Clone https://x-access-token:\(secret)@github.com/acme/private.git")]

        try await store.save(chat)
        let path = root.appendingPathComponent(ChatStore.relativePath(for: chat.id))
        let bytes = try Data(contentsOf: path)
        let savedText = String(decoding: bytes, as: UTF8.self)
        #expect(!savedText.contains(secret))
        #expect(savedText.contains("https://github.com/acme/private.git"))
        #expect(await store.load(chat.id)?.firstUserText?.contains(secret) == false)
    }
}
