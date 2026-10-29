import Foundation
import Testing
@testable import AgentCore

/// Enough of GitHub's Git data API, in memory, to test saving: blobs, trees, commits and one
/// branch that only moves forward.
final class FakeGitHub: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    var blobs: [String: Data] = [:]
    var trees: [String: [String: String]] = [:]
    var commits: [String: (tree: String, parent: String?)] = [:]
    var head: String?
    var branchHeads: [String: String] = [:]
    var pullState = "open"
    /// Runs once, just before the next branch update, to simulate another phone saving first.
    var beforeNextUpdate: (() -> Void)?

    struct Tokens: GitHubTokenProvider {
        func installationToken() async throws -> String { "installation" }
        func userToken() async throws -> String { "user" }
    }

    var client: GitHubClient { GitHubClient(transport: self, tokens: Tokens()) }

    func stream(_ request: HTTPRequest) async throws -> HTTPStreamResponse {
        HTTPStreamResponse(status: 500, headers: [:], body: AsyncThrowingStream { $0.finish() })
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        lock.withLock { handle(request) }
    }

    private func json(_ value: JSONValue, status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status, headers: ["content-type": "application/json"], body: Data(value.jsonString().utf8))
    }

    private func newID(_ seed: String) -> String {
        Hashing.sha256Hex(Data((seed + UUID().uuidString).utf8)).prefix(40).description
    }

    /// Adds a commit as if another device saved `files` (nil deletes a path).
    func commitRemotely(_ files: [String: Data?]) {
        lock.withLock {
            var tree = head.flatMap { commits[$0]?.tree }.flatMap { trees[$0] } ?? [:]
            for (path, data) in files {
                if let data {
                    let sha = Hashing.gitBlobID(data)
                    blobs[sha] = data
                    tree[path] = sha
                } else {
                    tree[path] = nil
                }
            }
            let treeID = newID("tree")
            trees[treeID] = tree
            let commitID = newID("commit")
            commits[commitID] = (treeID, head)
            head = commitID
        }
    }

    func remoteFile(_ path: String) -> Data? {
        lock.withLock {
            guard let head, let tree = commits[head]?.tree, let sha = trees[tree]?[path] else { return nil }
            return blobs[sha]
        }
    }

    private func handle(_ request: HTTPRequest) -> HTTPResponse {
        let path = request.url.path
        let body = request.body.flatMap(JSONValue.parse)
        let prefix = "/repos/octo/MAIPA-G-data"
        switch (request.method, path) {
        case ("GET", prefix):
            return json(["id": 7, "name": "MAIPA-G-data", "full_name": "octo/MAIPA-G-data", "owner": ["login": "octo"], "private": true, "default_branch": "main", "html_url": "https://github.com/octo/MAIPA-G-data"])
        case ("GET", prefix + "/git/ref/heads/main"):
            guard let head else { return json(["message": "Git Repository is empty."], status: 409) }
            return json(["object": ["sha": .string(head)]])
        case ("POST", prefix + "/git/refs"):
            guard let ref = body?["ref"]?.stringValue, let sha = body?["sha"]?.stringValue else { return json(["message": "bad"], status: 422) }
            branchHeads[String(ref.dropFirst("refs/heads/".count))] = sha
            return json(["ref": .string(ref), "object": ["sha": .string(sha)]], status: 201)
        case ("POST", prefix + "/pulls"):
            pullState = "open"
            return json(["number": 1, "title": body?["title"] ?? "Changes", "state": "open", "html_url": "https://github.com/octo/MAIPA-G-data/pull/1", "head": ["ref": body?["head"] ?? "branch"], "base": ["ref": body?["base"] ?? "main"], "merged": false], status: 201)
        case ("GET", prefix + "/pulls/1"):
            return json(["number": 1, "title": "Changes", "state": .string(pullState), "html_url": "https://github.com/octo/MAIPA-G-data/pull/1", "head": ["ref": "maipa-g/test"], "base": ["ref": "main"], "merged": .bool(pullState == "merged")])
        case ("PATCH", prefix + "/pulls/1"):
            pullState = body?["state"]?.stringValue ?? pullState
            return json(["number": 1, "title": "Changes", "state": .string(pullState), "html_url": "https://github.com/octo/MAIPA-G-data/pull/1", "head": ["ref": "maipa-g/test"], "base": ["ref": "main"], "merged": false])
        case ("PUT", prefix + "/pulls/1/merge"):
            pullState = "merged"
            return json(["merged": true])
        case ("PATCH", prefix + "/git/refs/heads/main"):
            if let hook = beforeNextUpdate {
                beforeNextUpdate = nil
                lock.unlock()
                hook()
                lock.lock()
            }
            guard let sha = body?["sha"]?.stringValue, let commit = commits[sha] else { return json(["message": "bad"], status: 422) }
            guard commit.parent == head else { return json(["message": "Update is not a fast forward"], status: 422) }
            head = sha
            return json(["object": ["sha": .string(sha)]])
        case ("POST", prefix + "/git/blobs"):
            let data = Data(base64Encoded: body?["content"]?.stringValue ?? "") ?? Data()
            let sha = Hashing.gitBlobID(data)
            blobs[sha] = data
            return json(["sha": .string(sha)], status: 201)
        case ("POST", prefix + "/git/trees"):
            var tree = body?["base_tree"]?.stringValue.flatMap { trees[$0] } ?? [:]
            for entry in body?["tree"]?.arrayValue ?? [] {
                guard let path = entry["path"]?.stringValue else { continue }
                tree[path] = entry["sha"]?.stringValue
            }
            let id = newID("tree")
            trees[id] = tree
            return json(["sha": .string(id)], status: 201)
        case ("POST", prefix + "/git/commits"):
            let id = newID("commit")
            commits[id] = (body?["tree"]?.stringValue ?? "", body?["parents"]?.arrayValue?.first?.stringValue)
            return json(["sha": .string(id)], status: 201)
        default:
            if request.method == "GET", path.hasPrefix(prefix + "/git/ref/heads/") {
                let branch = String(path.dropFirst((prefix + "/git/ref/heads/").count)).removingPercentEncoding ?? ""
                guard let sha = branchHeads[branch] else { return json(["message": "Not Found"], status: 404) }
                return json(["object": ["sha": .string(sha)]])
            }
            if request.method == "PATCH", path.hasPrefix(prefix + "/git/refs/heads/") {
                let branch = String(path.dropFirst((prefix + "/git/refs/heads/").count)).removingPercentEncoding ?? ""
                guard let sha = body?["sha"]?.stringValue, let commit = commits[sha], commit.parent == branchHeads[branch] else { return json(["message": "Update is not a fast forward"], status: 422) }
                branchHeads[branch] = sha
                return json(["object": ["sha": .string(sha)]])
            }
            if request.method == "DELETE", path.hasPrefix(prefix + "/git/refs/heads/") {
                let branch = String(path.dropFirst((prefix + "/git/refs/heads/").count)).removingPercentEncoding ?? ""
                branchHeads[branch] = nil
                return HTTPResponse(status: 204)
            }
            if request.method == "GET", path.hasPrefix(prefix + "/git/commits/") {
                let id = String(path.dropFirst((prefix + "/git/commits/").count))
                guard let commit = commits[id] else { return json(["message": "Not Found"], status: 404) }
                return json(["tree": ["sha": .string(commit.tree)]])
            }
            if request.method == "GET", path.hasPrefix(prefix + "/git/trees/") {
                let id = String(path.dropFirst((prefix + "/git/trees/").count))
                let treeID = commits[id]?.tree ?? id
                guard let tree = trees[treeID] else { return json(["message": "Not Found"], status: 404) }
                let entries: [JSONValue] = tree.sorted { $0.key < $1.key }.map { ["path": .string($0.key), "mode": "100644", "type": "blob", "sha": .string($0.value), "size": .number(Double(blobs[$0.value]?.count ?? 0))] }
                return json(["sha": .string(id), "tree": .array(entries), "truncated": false])
            }
            if request.method == "GET", path.hasPrefix(prefix + "/git/blobs/") {
                let id = String(path.dropFirst((prefix + "/git/blobs/").count))
                guard let data = blobs[id] else { return json(["message": "Not Found"], status: 404) }
                return HTTPResponse(status: 200, body: data)
            }
            return json(["message": .string("Not handled: \(request.method) \(path)")], status: 404)
        }
    }
}

@Suite("Saving to the data repo")
struct DataRepoSyncTests {
    struct Setup {
        let github = FakeGitHub()
        let directory: URL
        let sync: DataRepoSync
        let store: ChatStore

        init() async throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("maipag-sync-\(UUID().uuidString)", isDirectory: true)
            let data = directory.appendingPathComponent("data", isDirectory: true)
            try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
            github.commitRemotely(["README.md": Data("# MAIPA-G-data\n".utf8)])
            sync = DataRepoSync(github: github.client, dataDirectory: data, stateURL: directory.appendingPathComponent("sync-state.json"))
            store = ChatStore(dataDirectory: data)
            try await sync.ensureRepository(owner: "octo")
        }
    }

    static func chat(_ title: String, updated: Date) -> Chat {
        var chat = Chat(title: title)
        chat.messages = [.user("hello \(title)")]
        chat.updatedAt = updated
        return chat
    }

    @Test func uploadsDownloadsAndDeletes() async throws {
        let setup = try await Setup()
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        let one = Self.chat("one", updated: Date())
        let two = Self.chat("two", updated: Date())
        try await setup.store.save(one)
        try await setup.store.save(two)

        let first = try await setup.sync.sync()
        #expect(Set(first.uploaded) == [ChatStore.relativePath(for: one.id), ChatStore.relativePath(for: two.id)])
        #expect(setup.github.remoteFile(ChatStore.relativePath(for: one.id)) != nil)
        #expect(setup.github.remoteFile("README.md") != nil, "files MAIPA-G doesn't manage are left alone")

        // Nothing changed: no commit.
        let idle = try await setup.sync.sync()
        #expect(!idle.changedAnything && idle.commit == nil)

        // Another phone edits chat two.
        var edited = two
        edited.title = "two, edited elsewhere"
        edited.updatedAt = Date().addingTimeInterval(10)
        setup.github.commitRemotely([ChatStore.relativePath(for: two.id): try JSONCoding.encoder(pretty: true).encode(edited)])
        let pulled = try await setup.sync.sync()
        #expect(pulled.downloaded == [ChatStore.relativePath(for: two.id)])
        #expect(await setup.store.load(two.id)?.title == "two, edited elsewhere")

        // Deleting here deletes there.
        await setup.store.delete(one.id)
        let deleted = try await setup.sync.sync()
        #expect(deleted.deletedThere == [ChatStore.relativePath(for: one.id)])
        #expect(setup.github.remoteFile(ChatStore.relativePath(for: one.id)) == nil)

        // Deleted elsewhere, untouched here: it goes here too.
        setup.github.commitRemotely([ChatStore.relativePath(for: two.id): nil])
        let gone = try await setup.sync.sync()
        #expect(gone.deletedHere == [ChatStore.relativePath(for: two.id)])
        #expect(await setup.store.load(two.id) == nil)
    }

    @Test func bothSidesEditedKeepsTheNewest() async throws {
        let setup = try await Setup()
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        let base = Self.chat("base", updated: Date(timeIntervalSince1970: 1_000))
        try await setup.store.save(base)
        try await setup.sync.sync()

        var mine = base
        mine.title = "mine, newer"
        mine.updatedAt = Date(timeIntervalSince1970: 3_000)
        try await setup.store.save(mine)
        var theirs = base
        theirs.title = "theirs, older"
        theirs.updatedAt = Date(timeIntervalSince1970: 2_000)
        setup.github.commitRemotely([ChatStore.relativePath(for: base.id): try JSONCoding.encoder(pretty: true).encode(theirs)])

        let report = try await setup.sync.sync()
        #expect(report.uploaded == [ChatStore.relativePath(for: base.id)])
        let remote = try #require(setup.github.remoteFile(ChatStore.relativePath(for: base.id)))
        #expect(try JSONCoding.decoder().decode(Chat.self, from: remote).title == "mine, newer")
    }

    @Test func aRaceWithAnotherSaveIsRetried() async throws {
        let setup = try await Setup()
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        let mine = Self.chat("mine", updated: Date())
        try await setup.store.save(mine)
        let other = Self.chat("other phone", updated: Date())
        let otherPath = ChatStore.relativePath(for: other.id)
        let otherData = try JSONCoding.encoder(pretty: true).encode(other)
        let github = setup.github
        github.beforeNextUpdate = { github.commitRemotely([otherPath: otherData]) }

        let report = try await setup.sync.sync()
        #expect(report.uploaded == [ChatStore.relativePath(for: mine.id)])
        #expect(report.downloaded == [otherPath])
        #expect(github.remoteFile(ChatStore.relativePath(for: mine.id)) != nil)
        #expect(github.remoteFile(otherPath) != nil)
        #expect(await setup.store.load(other.id)?.title == "other phone")
    }

    @Test func syncsProductDocumentsAndAttachmentBlobs() async throws {
        let setup = try await Setup()
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        let product = ProductStore<MemoryRecord>(dataDirectory: setup.store.dataDirectory, folder: "memories")
        let memory = MemoryRecord(text: "Keep answers short")
        try await product.save(memory)
        let attachmentPath = "attachments/abc/photo.jpg"
        try await setup.store.saveBlob(Data([1, 2, 3, 4]), at: attachmentPath)

        let report = try await setup.sync.sync()
        #expect(report.uploaded.contains("memories/\(memory.id.uuidString.lowercased()).json"))
        #expect(report.uploaded.contains(attachmentPath))
        #expect(setup.github.remoteFile(attachmentPath) == Data([1, 2, 3, 4]))
        #expect(setup.github.remoteFile("README.md") != nil)
    }

    @Test func commitMessagesAreReadable() {
        #expect(DataRepoSync.commitMessage(uploads: ["chats/a.json"], deletes: []) == "Save 1 chat")
        #expect(DataRepoSync.commitMessage(uploads: ["chats/a.json", "chats/b.json", "settings.json"], deletes: ["chats/c.json"]) == "Save 2 chats and settings, remove 1 chat")
        #expect(DataRepoSync.commitMessage(uploads: [], deletes: ["chats/c.json"]) == "Remove 1 chat")
    }
}
