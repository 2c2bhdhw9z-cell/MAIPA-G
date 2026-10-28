import Foundation
import Testing
@testable import AgentCore

@Suite("Repo copies and search")
struct RepoCopyTests {
    /// Unpacks the fixture tarball the same way a real download is unpacked.
    static func unpackFixture() throws -> (snapshot: RepoSnapshot, unpacker: SnapshotUnpacker, root: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("maipag-tests-\(UUID().uuidString)", isDirectory: true)
        let files = root.appendingPathComponent("files", isDirectory: true)
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        var unpacker = SnapshotUnpacker(filesDirectory: files)
        var tar = TarReader()
        let inflater = try GzipInflater()
        // Feed it in awkward pieces, as a network download would arrive.
        let data = Fixtures.sampleTarball
        var offset = 0
        while offset < data.count {
            let end = min(offset + 97, data.count)
            try inflater.feed(data.subdata(in: offset..<end)) { piece in
                try tar.feed(piece, into: &unpacker)
            }
            offset = end
        }
        #expect(tar.isDone)
        let manifest = SnapshotManifest(
            formatVersion: 1,
            repo: RepoRef(owner: "octo", name: "repo"),
            commit: "abc1234567890abc1234567890abc1234567890a",
            createdAt: Date(),
            files: unpacker.files.sorted { $0.path < $1.path }
        )
        return (RepoSnapshot(directory: root, manifest: manifest), unpacker, root)
    }

    @Test func unpacksGitHubStyleTarball() throws {
        let (snapshot, unpacker, root) = try Self.unpackFixture()
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(unpacker.commitComment == "abc1234567890abc1234567890abc1234567890a")
        let paths = snapshot.manifest.files.map(\.path)
        let longPath = "src/" + String(repeating: "very_long_folder_name_", count: 6) + "/deeply/nested/file_with_a_long_name.txt"
        #expect(paths.contains("README.md"))
        #expect(paths.contains("src/main.swift"))
        #expect(paths.contains(longPath))
        #expect(paths.contains("café/naïve.txt"))
        #expect(!paths.contains { $0.contains("escape") })
        #expect(!FileManager.default.fileExists(atPath: root.deletingLastPathComponent().appendingPathComponent("escape.txt").path))

        #expect(snapshot.file("assets/logo.png")?.kind == .binary)
        #expect(snapshot.contents(of: "assets/logo.png") == nil)
        #expect(snapshot.file("link-to-readme")?.kind == .symlink)
        #expect(snapshot.file("link-to-readme")?.linkTarget == "README.md")
        #expect(snapshot.file("empty.txt")?.kind == .text)
        #expect(snapshot.contents(of: "empty.txt") == Data())
        #expect(String(decoding: snapshot.contents(of: "src/main.swift") ?? Data(), as: UTF8.self).contains("let token"))
        #expect(String(decoding: snapshot.contents(of: longPath) ?? Data(), as: UTF8.self) == "needle in a long path\n")
    }

    @Test func searchFindsLiteralRegexAndGlobMatches() async throws {
        let (snapshot, _, root) = try Self.unpackFixture()
        defer { try? FileManager.default.removeItem(at: root) }

        let literal = try await CodeSearch.run(SearchQuery(pattern: "token"), in: snapshot)
        #expect(literal.matches.map { "\($0.path):\($0.line)" } == ["README.md:4", "src/main.swift:2", "src/main.swift:3"])
        #expect(literal.filesMatched == 2)

        let caseSensitive = try await CodeSearch.run(SearchQuery(pattern: "Token", caseSensitive: true), in: snapshot)
        #expect(caseSensitive.matches.map(\.path) == ["README.md"])

        let regex = try await CodeSearch.run(SearchQuery(pattern: #"^let \w+ ="#, isRegex: true), in: snapshot)
        #expect(regex.matches.map(\.line) == [2])

        let globbed = try await CodeSearch.run(SearchQuery(pattern: "needle", pathGlob: "**/*.txt"), in: snapshot)
        #expect(globbed.matches.count == 1)
        let wrongGlob = try await CodeSearch.run(SearchQuery(pattern: "needle", pathGlob: "*.swift"), in: snapshot)
        #expect(wrongGlob.matches.isEmpty)

        let capped = try await CodeSearch.run(SearchQuery(pattern: "t", maxResults: 2), in: snapshot)
        #expect(capped.matches.count == 2 && capped.truncated)

        await #expect(throws: SearchError.self) { try await CodeSearch.run(SearchQuery(pattern: "(", isRegex: true), in: snapshot) }
    }

    @Test func unsafePathsAreRejected() {
        #expect(SnapshotStore.isSafeRelativePath("a/b.txt"))
        #expect(!SnapshotStore.isSafeRelativePath("../a"))
        #expect(!SnapshotStore.isSafeRelativePath("a/../../b"))
        #expect(!SnapshotStore.isSafeRelativePath("/etc/passwd"))
        #expect(!SnapshotStore.isSafeRelativePath("a//b"))
        #expect(!SnapshotStore.isSafeRelativePath(""))
    }

    @Test func gzipRejectsGarbage() throws {
        let inflater = try GzipInflater()
        #expect(throws: GzipInflater.Failure.self) {
            try inflater.feed(Data("this is not gzip at all, not even close".utf8)) { _ in }
        }
    }

    @Test func linkHeaderPagination() {
        let header = #"<https://api.github.com/installation/repositories?per_page=100&page=2>; rel="next", <https://api.github.com/installation/repositories?per_page=100&page=5>; rel="last""#
        #expect(GitHubClient.nextPage(from: header)?.absoluteString == "https://api.github.com/installation/repositories?per_page=100&page=2")
        #expect(GitHubClient.nextPage(from: #"<https://x.test/p1>; rel="prev""#) == nil)
    }

    @Test func pathEscapingKeepsSlashes() {
        #expect(GitHubClient.escapePath("docs/My File#1.md") == "docs/My%20File%231.md")
        #expect(GitHubClient.escape("feature/x") == "feature%2Fx")
    }
}

@Suite("GitHub app sign-in")
struct GitHubAuthTests {
    struct FakeSigner: RS256Signer {
        func sign(_ message: Data) throws -> Data { Data(message.reversed().prefix(16)) }
    }

    @Test func jwtHasTheShapeGitHubExpects() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let jwt = try GitHubAppJWT.make(clientID: "Iv23abc", signer: FakeSigner(), now: now)
        let parts = jwt.split(separator: ".").map(String.init)
        #expect(parts.count == 3)
        let header = try #require(Base64URL.decode(parts[0]).flatMap(JSONValue.parse))
        let payload = try #require(Base64URL.decode(parts[1]).flatMap(JSONValue.parse))
        #expect(header == ["alg": "RS256", "typ": "JWT"])
        #expect(payload["iss"] == "Iv23abc")
        #expect(payload["iat"]?.intValue == 1_800_000_000 - 60)
        #expect(payload["exp"]?.intValue == 1_800_000_000 - 60 + 540)
    }

    @Test func pkcs8IsUnwrappedToPKCS1() throws {
        // PrivateKeyInfo { version 0, AlgorithmIdentifier { rsaEncryption, NULL }, OCTET STRING { inner } }
        let inner: [UInt8] = [0x30, 0x03, 0x02, 0x01, 0x00]
        let algorithm: [UInt8] = [0x30, 0x0d, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01, 0x05, 0x00]
        let octet: [UInt8] = [0x04, UInt8(inner.count)] + inner
        let body: [UInt8] = [0x02, 0x01, 0x00] + algorithm + octet
        let der: [UInt8] = [0x30, UInt8(body.count)] + body
        let pem = "-----BEGIN PRIVATE KEY-----\n\(Data(der).base64EncodedString())\n-----END PRIVATE KEY-----\n"
        #expect(try PEM.rsaPrivateKeyPKCS1(pem) == Data(inner))
        let pkcs1 = "-----BEGIN RSA PRIVATE KEY-----\n\(Data(inner).base64EncodedString())\n-----END RSA PRIVATE KEY-----"
        #expect(try PEM.rsaPrivateKeyPKCS1(pkcs1) == Data(inner))
        #expect(throws: PEM.Failure.self) { try PEM.rsaPrivateKeyPKCS1("not a key") }
    }

    #if canImport(Security)
    @Test func securitySignerMakesVerifiableRS256() throws {
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048]
        var error: Unmanaged<CFError>?
        let key = try #require(SecKeyCreateRandomKey(attributes as CFDictionary, &error))
        let der = try #require(SecKeyCopyExternalRepresentation(key, &error) as Data?)
        let pem = "-----BEGIN RSA PRIVATE KEY-----\n" + der.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed]) + "\n-----END RSA PRIVATE KEY-----\n"
        let signer = try SecurityRS256Signer(pem: pem)
        let message = Data("header.payload".utf8)
        let signature = try signer.sign(message)
        #expect(signature.count == 256)
        #expect(signer.verify(signature, for: message))
        #expect(!signer.verify(signature, for: Data("tampered".utf8)))
    }
    #endif
}
