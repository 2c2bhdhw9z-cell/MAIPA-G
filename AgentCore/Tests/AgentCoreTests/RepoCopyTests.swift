import Clibsodium
import Foundation
import Testing
@testable import AgentCore

private struct FixedGitHubToken: GitHubTokenProvider {
    func installationToken() async throws -> String { "token" }
    func userToken() async throws -> String { "token" }
}

private final class ActionsTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var requestsStorage: [HTTPRequest] = []
    var publicKey: [UInt8]
    var secretKey: [UInt8]

    init() {
        publicKey = [UInt8](repeating: 0, count: Int(crypto_box_publickeybytes()))
        secretKey = [UInt8](repeating: 0, count: Int(crypto_box_secretkeybytes()))
        _ = sodium_init()
        _ = crypto_box_keypair(&publicKey, &secretKey)
    }

    var requests: [HTTPRequest] { lock.withLock { requestsStorage } }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        lock.withLock { requestsStorage.append(request) }
        let path = request.url.path
        if path.hasSuffix("/actions/secrets/public-key") {
            let body: JSONValue = ["key_id": "key-1", "key": .string(Data(publicKey).base64EncodedString())]
            return HTTPResponse(status: 200, body: try JSONCoding.encoder().encode(body))
        }
        if path.contains("/actions/secrets/") { return HTTPResponse(status: 201) }
        if path.hasSuffix("/actions/workflows/maipa-g.yml/dispatches") { return HTTPResponse(status: 204) }
        if path.hasSuffix("/actions/runs") {
            return HTTPResponse(status: 200, body: Data(#"{"workflow_runs":[{"id":7,"name":"iOS","status":"completed","conclusion":"success","event":"push","head_branch":"main","head_sha":"abc","html_url":"https://example.test/run/7","run_number":12,"created_at":"2026-10-28T00:00:00Z","updated_at":"2026-10-28T00:01:00Z"}]}"#.utf8))
        }
        return HTTPResponse(status: 404, body: Data(#"{"message":"missing"}"#.utf8))
    }

    func stream(_ request: HTTPRequest) async throws -> HTTPStreamResponse {
        HTTPStreamResponse(status: 404, headers: [:], body: AsyncThrowingStream { $0.finish() })
    }
}

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

    @Test func stagedSaveAndUndoProtectAgainstInterveningChanges() async throws {
        let github = FakeGitHub()
        github.commitRemotely(["README.md": Data("old\n".utf8)])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("maipag-change-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let head = try #require(github.head)
        let repo = RepoRef(owner: "octo", name: "MAIPA-G-data")
        let base = RepoWorkspace(repo: repo, branch: "main", commit: head, github: github.client, store: SnapshotStore(root: root))
        let changes = ChangeWorkspace(base: base)
        try await changes.edit(path: "README.md", text: "new\n")
        try await changes.create(path: "Sources/New.swift", text: "let value = 1\n")
        await #expect(throws: ChangeWorkspaceError.self) { try await changes.delete(path: "README.md") }

        let service = GitHubChangeService(github: github.client)
        let receipt = try await service.save(changes, selectedBranch: "main", defaultBranch: "main", rules: RepoWriteRules(directSave: true), title: "Update files")
        #expect(github.remoteFile("README.md") == Data("new\n".utf8))
        #expect(github.remoteFile("Sources/New.swift") != nil)
        _ = try await service.undo(receipt)
        #expect(github.remoteFile("README.md") == Data("old\n".utf8))
        #expect(github.remoteFile("Sources/New.swift") == nil)

        let secondBase = RepoWorkspace(repo: repo, branch: "main", commit: try #require(github.head), github: github.client, store: SnapshotStore(root: root))
        let secondChanges = ChangeWorkspace(base: secondBase)
        try await secondChanges.edit(path: "README.md", text: "again\n")
        let second = try await service.save(secondChanges, selectedBranch: "main", defaultBranch: "main", rules: RepoWriteRules(directSave: true), title: "Again")
        github.commitRemotely(["OTHER.md": Data("intervening".utf8)])
        await #expect(throws: ChangeWorkspaceError.self) { _ = try await service.undo(second) }
        #expect(github.remoteFile("OTHER.md") != nil)
    }

    @Test func defaultBranchSaveOpensAndResolvesPullRequest() async throws {
        let github = FakeGitHub()
        github.commitRemotely(["README.md": Data("old\n".utf8)])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("maipag-pr-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let base = RepoWorkspace(repo: RepoRef(owner: "octo", name: "MAIPA-G-data"), branch: "main", commit: try #require(github.head), github: github.client, store: SnapshotStore(root: root))
        let changes = ChangeWorkspace(base: base)
        try await changes.edit(path: "README.md", text: "new\n")
        let service = GitHubChangeService(github: github.client)
        let receipt = try await service.save(changes, selectedBranch: "main", defaultBranch: "main", rules: RepoWriteRules(), title: "Update readme")
        #expect(receipt.branch.hasPrefix("maipa-g/update-readme-"))
        #expect(receipt.pullRequest?.number == 1)
        #expect(github.branchHeads[receipt.branch] == receipt.savedCommit)
        try await service.addIt(receipt)
        #expect(github.pullState == "merged")
        #expect(github.branchHeads[receipt.branch] == nil)
    }

    @Test func laterSaveAppendsToTheOpenPullRequestBranch() async throws {
        let github = FakeGitHub()
        github.commitRemotely(["README.md": Data("old\n".utf8)])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("maipag-pr-append-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = RepoRef(owner: "octo", name: "MAIPA-G-data")
        let firstBase = RepoWorkspace(repo: repo, branch: "main", commit: try #require(github.head), github: github.client, store: SnapshotStore(root: root))
        let firstChanges = ChangeWorkspace(base: firstBase)
        try await firstChanges.edit(path: "README.md", text: "first\n")
        let service = GitHubChangeService(github: github.client)
        let first = try await service.save(firstChanges, selectedBranch: "main", defaultBranch: "main", rules: RepoWriteRules(), title: "Update readme")

        let secondBase = RepoWorkspace(repo: repo, branch: first.branch, commit: first.savedCommit, github: github.client, store: SnapshotStore(root: root))
        let secondChanges = ChangeWorkspace(base: secondBase)
        try await secondChanges.edit(path: "README.md", text: "second\n")
        let second = try await service.save(secondChanges, selectedBranch: first.branch, defaultBranch: "main", rules: RepoWriteRules(), title: "Continue update", activeReceipt: first)
        #expect(second.branch == first.branch)
        #expect(second.pullRequest?.number == first.pullRequest?.number)
        #expect(github.commits[second.savedCommit]?.parent == first.savedCommit)
        #expect(github.branchHeads[first.branch] == second.savedCommit)
    }

    @Test func repositoryRulesForceDirectSaving() {
        let rules = RepoWriteRules.resolve(documents: [
            (".kiro/steering/owner-rules.md", "Commit directly to main. Do not change build setup."),
            ("Sources/Generated/AGENTS.md", "Never delete files in this folder."),
        ], directSaveSetting: false)
        #expect(rules.directSave)
        #expect(rules.reason?.contains("owner-rules.md") == true)
        #expect(!rules.permitsBuildSetup(at: "Package.swift"))
        #expect(!rules.permitsDeletion(at: "Sources/Generated/Old.swift"))
        #expect(rules.permitsDeletion(at: "Sources/Keep.swift"))
        #expect(rules.promptText.contains("Sources/Generated/AGENTS.md"))
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

    @Test func actionsRequestsDispatchRunsAndEncryptedSecrets() async throws {
        let transport = ActionsTransport()
        let client = GitHubClient(transport: transport, tokens: FixedGitHubToken())
        let repo = RepoRef(owner: "octo", name: "repo")
        try await client.dispatchWorkflow(repo, workflow: "maipa-g.yml", ref: "main", inputs: ["job_id": "opaque-id"])
        let runs = try await client.workflowRuns(repo)
        #expect(runs.first?.runNumber == 12)
        let watched = try await GitHubRunWatcher(github: client, maximumPolls: 1, sleeper: {}).wait(repo: repo, commit: "abc", redacting: RedactingLogger(secrets: ["secret-token"]))
        #expect(watched.succeeded)
        #expect(watched.runs.allSatisfy { $0.headSHA == "abc" })
        try await client.putActionsSecret(repo, name: "OPENROUTER_API_KEY", value: "private-value")

        let dispatch = try #require(transport.requests.first { $0.url.path.hasSuffix("/dispatches") })
        let dispatchBody = try #require(dispatch.body.flatMap(JSONValue.parse))
        #expect(dispatchBody["inputs"]?["job_id"] == "opaque-id")
        let upload = try #require(transport.requests.first { $0.url.path.hasSuffix("/actions/secrets/OPENROUTER_API_KEY") })
        let uploadBody = try #require(upload.body.flatMap(JSONValue.parse))
        #expect(uploadBody["key_id"] == "key-1")
        #expect(uploadBody["encrypted_value"] != "private-value")
        let encrypted = try #require(uploadBody["encrypted_value"]?.stringValue)
        let cipher = try #require(Data(base64Encoded: encrypted))
        var clear = [UInt8](repeating: 0, count: cipher.count - Int(crypto_box_sealbytes()))
        let opened = cipher.withUnsafeBytes { bytes in
            crypto_box_seal_open(&clear, bytes.bindMemory(to: UInt8.self).baseAddress!, UInt64(cipher.count), &transport.publicKey, &transport.secretKey)
        }
        #expect(opened == 0)
        #expect(String(decoding: clear, as: UTF8.self) == "private-value")

        let worktree = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let reusable = try String(contentsOf: worktree.appendingPathComponent(".github/workflows/agent.yml"), encoding: .utf8)
        // The target checkout keeps no credential, and the trusted runner is cloned outside the
        // target repo, where commands the AI runs in that repo can't swap its files.
        #expect(reusable.components(separatedBy: "persist-credentials: false").count == 2)
        #expect(reusable.contains("\"$RUNNER_TEMP/maipag-runner\""))
        #expect(!reusable.contains("path: .maipag-runner"))
        #expect(!reusable.contains("GH_TOKEN:"))
        #expect(reusable.contains("MAIPAG_TARGET_TOKEN"))
        #expect(reusable.contains("MAIPAG_DATA_TOKEN"))
    }

    @Test func buildInspectionDoesNotDispatch() async throws {
        let transport = ActionsTransport()
        let client = GitHubClient(transport: transport, tokens: FixedGitHubToken())
        let inspector = GitHubBuildInspector(github: client)
        try await inspector.dispatch(repo: RepoRef(owner: "octo", name: "repo"), workflow: "ios.yml", ref: "main", explicitlyRequested: false)
        #expect(transport.requests.isEmpty)
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
