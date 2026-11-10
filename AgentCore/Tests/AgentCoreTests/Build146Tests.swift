import Foundation
import Testing
@testable import AgentCore

/// A tiny GitLab server: one project with a main branch, commits, branches and merge requests.
final class FakeGitLab: HTTPTransport, @unchecked Sendable {
    let lock = NSLock()
    var branches: [String: String] = ["main": "c1"]
    var commitFiles: [String: [String: Data]] = ["c1": ["README.md": Data("hello\n".utf8), "docs/a.txt": Data("a\n".utf8)]]
    var commitBodies: [JSONValue] = []
    var mergeRequests: [JSONValue] = []
    var requests: [HTTPRequest] = []
    var protectMain = false
    let project = "/api/v4/projects/grp%2Fsub%2Fproj"

    func blobs() -> [String: Data] {
        var all: [String: Data] = [:]
        for files in commitFiles.values { for data in files.values { all[Hashing.gitBlobID(data)] = data } }
        return all
    }

    func json(_ value: JSONValue, status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status, headers: ["content-type": "application/json"], body: try! JSONCoding.encoder().encode(value))
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        lock.withLock { handle(request) }
    }

    func handle(_ request: HTTPRequest) -> HTTPResponse {
        requests.append(request)
        #expect(request.headers["PRIVATE-TOKEN"] == "glpat-test")
        let components = URLComponents(url: request.url, resolvingAgainstBaseURL: false)!
        let path = components.percentEncodedPath
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        let body = request.body.flatMap(JSONValue.parse)
        guard path.hasPrefix(project) else { return json(["message": "404 Project Not Found"], status: 404) }
        let rest = String(path.dropFirst(project.count))
        switch (request.method, rest) {
        case ("GET", "/repository/tree"):
            let files = commitFiles[query["ref"] ?? ""] ?? [:]
            var entries: [JSONValue] = files.keys.sorted().map { ["id": .string(Hashing.gitBlobID(files[$0]!)), "path": .string($0), "type": "blob", "mode": "100644", "name": .string($0)] }
            entries.append(["id": "t1", "path": "docs", "type": "tree", "mode": "040000", "name": "docs"])
            var response = json(.array(entries))
            response.headers["x-next-page"] = ""
            return response
        case ("POST", "/repository/commits"):
            let branch = body?["branch"]?.stringValue ?? ""
            if protectMain && branch == "main" { return json(["message": "You are not allowed to push into this branch"], status: 403) }
            guard let head = branches[branch] else { return json(["message": "branch missing"], status: 400) }
            var files = commitFiles[head] ?? [:]
            for action in body?["actions"]?.arrayValue ?? [] {
                let file = action["file_path"]!.stringValue!
                switch action["action"]!.stringValue! {
                case "delete": files[file] = nil
                case "create":
                    #expect(files[file] == nil)
                    files[file] = Data(base64Encoded: action["content"]!.stringValue!)
                default:
                    #expect(files[file] != nil)
                    files[file] = Data(base64Encoded: action["content"]!.stringValue!)
                }
            }
            commitBodies.append(body!)
            let sha = "c\(commitFiles.count + 1)"
            commitFiles[sha] = files
            branches[branch] = sha
            return json(["id": .string(sha)], status: 201)
        case ("POST", "/repository/branches"):
            branches[query["branch"]!] = query["ref"]!
            return json(["name": .string(query["branch"]!)], status: 201)
        case ("GET", "/merge_requests"):
            return json(.array(mergeRequests.filter { $0["source_branch"]?.stringValue == query["source_branch"] && $0["state"] == "opened" }))
        case ("POST", "/merge_requests"):
            let mr: JSONValue = ["iid": .number(Double(mergeRequests.count + 1)), "title": body!["title"]!, "state": "opened",
                                 "web_url": .string("https://gitlab.example.com/grp/sub/proj/-/merge_requests/\(mergeRequests.count + 1)"),
                                 "source_branch": body!["source_branch"]!, "target_branch": body!["target_branch"]!]
            mergeRequests.append(mr)
            return json(mr, status: 201)
        default:
            if request.method == "GET", rest.hasPrefix("/repository/branches/") {
                let name = String(rest.dropFirst("/repository/branches/".count)).removingPercentEncoding!
                guard let sha = branches[name] else { return json(["message": "404 Branch Not Found"], status: 404) }
                return json(["name": .string(name), "commit": ["id": .string(sha)]])
            }
            if request.method == "GET", rest.hasPrefix("/repository/blobs/"), rest.hasSuffix("/raw") {
                let sha = String(rest.dropFirst("/repository/blobs/".count).dropLast("/raw".count))
                guard let data = blobs()[sha] else { return json(["message": "404"], status: 404) }
                return HTTPResponse(status: 200, body: data)
            }
            if request.method == "GET", rest.hasPrefix("/repository/commits/") {
                let ref = String(rest.dropFirst("/repository/commits/".count)).removingPercentEncoding!
                guard let sha = branches[ref] ?? (commitFiles[ref] != nil ? ref : nil) else { return json(["message": "404"], status: 404) }
                return json(["id": .string(sha)])
            }
            return json(["message": .string("unexpected \(request.method) \(rest)")], status: 500)
        }
    }

    func stream(_ request: HTTPRequest) async throws -> HTTPStreamResponse {
        let response = try await send(request)
        return HTTPStreamResponse(status: response.status, headers: response.headers, body: AsyncThrowingStream {
            if !response.body.isEmpty { $0.yield(response.body) }
            $0.finish()
        })
    }
}

@Suite("Build 146: GitLab, several repos, pictures as input")
struct Build146Tests {
    static let repo = RepoRef(owner: "grp/sub", name: "proj", host: "gitlab.example.com")

    static func setUp(_ server: FakeGitLab) -> (GitHubClient, RepoWorkspace, ChangeWorkspace) {
        var client = GitHubClient(transport: server, tokens: nil)
        client.gitLab = GitLabClient(host: "https://gitlab.example.com/", token: "glpat-test", transport: server)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gl-\(UUID().uuidString)")
        let base = RepoWorkspace(repo: repo, branch: "main", commit: "c1", github: client, store: SnapshotStore(root: root))
        return (client, base, ChangeWorkspace(base: base))
    }

    @Test("GitLab addresses: gitlab.com by default, https only, a self-hosted path kept")
    func hostNormalising() {
        #expect(GitLabClient.normalizedHost("") == "gitlab.com")
        #expect(GitLabClient.normalizedHost(" https://Git.Example.com/ ") == "git.example.com")
        #expect(GitLabClient.normalizedHost("https://example.com/gitlab/api/v4") == "example.com/gitlab")
        #expect(GitLabClient.normalizedHost("http://example.com") == nil)
        #expect(GitLabClient.projectID(Self.repo) == "grp%2Fsub%2Fproj")
        #expect(Self.repo.webURL.absoluteString == "https://gitlab.example.com/grp/sub/proj")
        #expect(Self.repo.isGitLab && Self.repo.hostName == "GitLab" && !RepoRef(owner: "a", name: "b").isGitLab)
    }

    @Test("Old saved repos without a host still read as GitHub repos")
    func repoRefStaysCompatible() throws {
        let old = try JSONCoding.decoder().decode(RepoRef.self, from: Data(#"{"owner":"a","name":"b"}"#.utf8))
        #expect(old == RepoRef(owner: "a", name: "b") && old.host == nil)
        let round = try JSONCoding.decoder().decode(RepoRef.self, from: JSONCoding.encoder().encode(Self.repo))
        #expect(round == Self.repo)
        let gitHubRepo = GitHubRepo(id: 1, name: "proj", fullName: "grp/sub/proj", ownerLogin: "grp/sub", isPrivate: true, defaultBranch: "main", htmlURL: "x", host: "gitlab.example.com")
        let decoded = try JSONCoding.decoder().decode(GitHubRepo.self, from: JSONCoding.encoder().encode(gitHubRepo))
        #expect(decoded.ref == Self.repo)
    }

    @Test("A GitLab project maps onto the repo list with its nested group as owner")
    func projectMapping() {
        let client = GitLabClient(host: "gitlab.example.com", token: "t", transport: FakeGitLab())
        let value: JSONValue = ["id": 7, "path": "proj", "path_with_namespace": "grp/sub/proj", "namespace": ["full_path": "grp/sub"],
                                "visibility": "internal", "default_branch": "trunk", "web_url": "https://gitlab.example.com/grp/sub/proj",
                                "last_activity_at": "2026-11-10T12:00:00.123Z"]
        let project = client.project(from: value)
        #expect(project?.ref == Self.repo)
        #expect(project?.isPrivate == true && project?.defaultBranch == "trunk" && project?.pushedAt != nil)
    }

    @Test("A GitLab repo is never sent to GitHub when GitLab isn't connected")
    func gitLabNeedsItsOwnConnection() async {
        let client = GitHubClient(transport: FakeGitLab(), tokens: nil)
        await #expect(throws: GitHubAPIError.self) { _ = try await client.tree(Self.repo, sha: "c1") }
    }

    @Test("Reading a GitLab tree and file goes through the same repo tools")
    func readsThroughWorkspace() async throws {
        let server = FakeGitLab()
        let (_, base, changes) = Self.setUp(server)
        let tree = try await base.tree()
        #expect(tree.entries.filter(\.isFile).map(\.path).sorted() == ["README.md", "docs/a.txt"])
        let output = try await ReadFileTool(workspace: base, changes: changes).run(arguments: ["path": "README.md"]) { _ in }
        #expect(output.forModel.contains("hello"))
    }

    @Test("Direct save on GitLab makes one commit on the branch, and Undo puts the files back")
    func directSaveAndUndo() async throws {
        let server = FakeGitLab()
        let (client, _, changes) = Self.setUp(server)
        _ = try await EditFileTool(workspace: changes, authorization: ChangeAuthorization(request: "edit"), rules: RepoWriteRules(directSave: true))
            .run(arguments: ["path": "README.md", "old_text": "hello", "new_text": "hi there"]) { _ in }
        _ = try await CreateFileTool(workspace: changes, authorization: ChangeAuthorization(request: "add"), rules: RepoWriteRules(directSave: true))
            .run(arguments: ["path": "new.txt", "content": "new\n"]) { _ in }
        let service = GitHubChangeService(github: client)
        let receipt = try await service.save(changes, selectedBranch: "main", defaultBranch: "main", rules: RepoWriteRules(directSave: true), title: "Edit readme")
        #expect(receipt.pullRequest == nil && receipt.branch == "main" && receipt.repo == Self.repo)
        let actions = server.commitBodies.last?["actions"]?.arrayValue ?? []
        #expect(Set(actions.compactMap { $0["action"]?.stringValue }) == ["update", "create"])
        let saved = server.commitFiles[receipt.savedCommit] ?? [:]
        #expect(String(decoding: saved["README.md"] ?? Data(), as: UTF8.self) == "hi there\n")
        #expect(receipt.files.first { $0.path == "README.md" }?.afterBlob == Hashing.gitBlobID(saved["README.md"]!))
        #expect(changes.base.commit == receipt.savedCommit)

        let undo = try await service.undo(receipt)
        let restored = server.commitFiles[undo.savedCommit] ?? [:]
        #expect(String(decoding: restored["README.md"] ?? Data(), as: UTF8.self) == "hello\n")
        #expect(restored["new.txt"] == nil)
    }

    @Test("With direct save off, or a protected branch, GitLab gets a side branch and a merge request")
    func mergeRequestFlow() async throws {
        for protected in [false, true] {
            let server = FakeGitLab()
            server.protectMain = protected
            let (client, _, changes) = Self.setUp(server)
            _ = try await CreateFileTool(workspace: changes, authorization: ChangeAuthorization(request: "add"), rules: RepoWriteRules(directSave: protected))
                .run(arguments: ["path": "x.txt", "content": "x"]) { _ in }
            let receipt = try await GitHubChangeService(github: client).save(
                changes, selectedBranch: "main", defaultBranch: "main", rules: RepoWriteRules(directSave: protected), title: "Add x"
            )
            #expect(receipt.branch.hasPrefix("maipa-g/"))
            #expect(server.branches["main"] == "c1")
            let pull = try #require(receipt.pullRequest)
            #expect(pull.number == 1 && pull.state == "open" && pull.htmlURL.contains("merge_requests/1"))
            #expect(server.mergeRequests.first?["target_branch"] == "main")
        }
    }

    @Test("A chat with one repo keeps its tools as they are; several repos share one tool per job")
    func routedTools() async throws {
        struct Echo: AgentTool {
            let name: String
            let tag: String
            var spec: ToolSpec { ToolSpec(name: name, description: "Echo.", parameters: ["type": "object", "properties": ["path": ["type": "string"]]]) }
            func runningSummary(for arguments: JSONValue) -> String { "Echo" }
            func run(arguments: JSONValue, progress: @escaping @Sendable (String) -> Void) async throws -> ToolOutput {
                #expect(arguments["repo"] == nil)
                return ToolOutput(forModel: "\(tag):\(arguments["path"]?.stringValue ?? "")", summary: "ok")
            }
        }
        let single = RepoRoutedTool.combine([("a/one", [Echo(name: "read_file", tag: "one")])])
        #expect(single.count == 1 && !(single[0] is RepoRoutedTool))

        let combined = RepoRoutedTool.combine([
            ("a/one", [Echo(name: "read_file", tag: "one"), Echo(name: "only_first", tag: "one")]),
            ("grp/sub/two", [Echo(name: "read_file", tag: "two")]),
        ])
        #expect(combined.map(\.name) == ["read_file", "only_first"])
        let routed = try #require(combined[0] as? RepoRoutedTool)
        #expect(routed.spec.function.parameters["properties"]?["repo"]?["enum"] == ["a/one", "grp/sub/two"])
        #expect(try await routed.run(arguments: ["path": "x"]) { _ in }.forModel == "one:x")
        #expect(try await routed.run(arguments: ["path": "x", "repo": "grp/sub/two"]) { _ in }.forModel == "two:x")
        #expect(try await routed.run(arguments: ["path": "y", "repo": "TWO"]) { _ in }.forModel == "two:y")
        await #expect(throws: ToolInputError.self) { _ = try await routed.run(arguments: ["path": "x", "repo": "nope"]) { _ in } }
        #expect(!(combined[1] is RepoRoutedTool))
    }

    @Test("Each repo continues only its own open request")
    func activeReceiptPerRepo() async {
        let pull = GitHubPullRequest(number: 3, title: "t", htmlURL: "u", headBranch: "maipa-g/x", baseBranch: "main")
        let other = RepoRef(owner: "a", name: "b")
        let session = ChangeSession(receipts: [SaveReceipt(repo: other, branch: "maipa-g/x", baseCommit: "1", savedCommit: "2", files: [], pullRequest: pull)])
        #expect(await session.activeReceipt()?.repo == other)
        #expect(await session.activeReceipt(for: other) != nil)
        #expect(await session.activeReceipt(for: Self.repo) == nil)
        let id = await session.receipts()[0].id
        await session.markResolved(id, as: "closed")
        #expect(await session.activeReceipt(for: other) == nil)
    }

    // MARK: Pictures as input

    @Test("Asking to change the earlier picture is recognised; a fresh request is not")
    func editIntent() {
        #expect(ImageEditIntent.refersToEarlierPicture("Make that picture brighter"))
        #expect(ImageEditIntent.refersToEarlierPicture("now change the background of it to blue"))
        #expect(!ImageEditIntent.refersToEarlierPicture("Draw a cat on a skateboard"))
    }

    final class ImageCapture: HTTPTransport, @unchecked Sendable {
        let lock = NSLock(); var request: HTTPRequest?
        func send(_ request: HTTPRequest) async throws -> HTTPResponse {
            lock.withLock { self.request = request }
            return HTTPResponse(status: 200, body: Data(#"{"data":[{"b64_json":"AQID","mime_type":"image/png"}]}"#.utf8))
        }
        func stream(_ request: HTTPRequest) async throws -> HTTPStreamResponse { HTTPStreamResponse(status: 404, headers: [:], body: AsyncThrowingStream { $0.finish() }) }
    }

    @Test("A picture goes to OpenRouter's images endpoint as an input reference")
    func inputReferencesAreSent() async throws {
        let transport = ImageCapture()
        let input = ImageInput(name: "cat.png", mimeType: "image/png", data: Data([9, 9]))
        _ = try await OpenRouterClient(transport: transport, apiKey: "key").generateImages(prompt: "Make it blue", model: "image/model", inputImages: [input])
        let body = try #require(transport.request?.body.flatMap(JSONValue.parse))
        let reference = try #require(body["input_references"]?.arrayValue?.first)
        #expect(reference["type"] == "image_url")
        #expect(reference["image_url"]?["url"]?.stringValue == "data:image/png;base64,CQk=")
    }

    @Test("A provider gateway gets a multipart image edit with every picture")
    func multipartEdit() throws {
        let request = AIProviderGateway.imageEditRequest(
            url: URL(string: "https://api.example.com/v1/images/edits")!, model: "m", prompt: "p", count: 1, size: "1024x1024",
            images: [ImageInput(name: "a.png", mimeType: "image/png", data: Data("AAA".utf8)), ImageInput(name: "b.jpg", mimeType: "image/jpeg", data: Data("BBB".utf8))],
            headers: ["Authorization": "Bearer k"]
        )
        #expect(request.method == "POST" && request.headers["Authorization"] == "Bearer k")
        #expect(request.headers["Content-Type"]?.hasPrefix("multipart/form-data; boundary=") == true)
        let text = String(decoding: request.body ?? Data(), as: UTF8.self)
        #expect(text.components(separatedBy: "name=\"image[]\"").count == 3)
        #expect(text.contains("AAA") && text.contains("BBB") && text.contains("name=\"prompt\""))
    }

    @Test("The picture tool offers chat pictures by name and rejects names it doesn't have")
    func toolOffersPictures() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("img-\(UUID().uuidString)")
        let store = AttachmentStore(dataDirectory: root)
        let reference = try await store.importGeneratedImage(Data([1, 2]), name: "picture-1.png", mimeType: "image/png")
        let client = OpenRouterClient(transport: ImageCapture(), apiKey: "key")
        let tool = GenerateImageTool(client: client, store: store, model: "image/model", maySpend: false, availableImages: [reference])
        #expect(tool.spec.function.parameters["properties"]?["reference_images"] != nil)
        let inputs = try await tool.inputImages(named: [reference.name])
        #expect(inputs.first?.data == Data([1, 2]))
        await #expect(throws: ToolInputError.self) { _ = try await tool.inputImages(named: ["missing.png"]) }
        let plain = GenerateImageTool(client: client, store: store, model: "image/model", maySpend: false)
        #expect(plain.spec.function.parameters["properties"]?["reference_images"] == nil)
    }
}
