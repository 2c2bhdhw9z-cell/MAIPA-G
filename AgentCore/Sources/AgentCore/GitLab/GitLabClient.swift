import Foundation

/// GitLab's REST API (v4), for gitlab.com or a self-hosted server, with a personal access token.
/// It answers the same questions `GitHubClient` answers for a repo, in the same shapes, so the
/// repo tools, snapshots and saving work unchanged. GitLab projects are `RepoRef`s whose `host`
/// is set; their owner is the full group path.
public struct GitLabClient: Sendable {
    public static let defaultHost = "gitlab.com"

    /// "gitlab.com", or a self-hosted server such as "git.example.com" or "example.com/gitlab".
    public let host: String
    let token: String
    let transport: any HTTPTransport

    public init(host: String, token: String, transport: any HTTPTransport) {
        self.host = Self.normalizedHost(host) ?? Self.defaultHost
        self.token = token
        self.transport = transport
    }

    /// Accepts "gitlab.com", "https://git.example.com/", or "https://example.com/gitlab". Plain
    /// http is refused: the token must never travel unencrypted.
    public static func normalizedHost(_ input: String) -> String? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return defaultHost }
        let lower = text.lowercased()
        if lower.hasPrefix("http://") { return nil }
        if lower.hasPrefix("https://") { text = String(text.dropFirst("https://".count)) }
        while text.hasSuffix("/") { text.removeLast() }
        if text.lowercased().hasSuffix("/api/v4") { text = String(text.dropLast("/api/v4".count)) }
        guard !text.isEmpty, !text.contains(" "), !text.contains("?"), !text.contains("#"),
              let url = URL(string: "https://" + text), let name = url.host, !name.isEmpty else { return nil }
        _ = name
        let parts = text.split(separator: "/", maxSplits: 1).map(String.init)
        return parts[0].lowercased() + (parts.count > 1 ? "/" + parts[1] : "")
    }

    public var apiBase: String { "https://\(host)/api/v4" }

    // MARK: Plumbing

    /// GitLab names a project by its URL-encoded full path ("group%2Fsub%2Fproject").
    static func projectID(_ repo: RepoRef) -> String {
        escape(repo.owner + "/" + repo.name)
    }

    static func escape(_ text: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }

    func url(_ path: String, query: [String: String] = [:]) throws -> URL {
        guard var components = URLComponents(string: apiBase) else { throw GitHubAPIError(status: 400, message: "That GitLab address isn't valid.") }
        components.percentEncodedPath += path.hasPrefix("/") ? path : "/" + path
        if !query.isEmpty {
            components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components.url else { throw GitHubAPIError(status: 400, message: "That GitLab address isn't valid.") }
        return url
    }

    var headers: [String: String] {
        ["PRIVATE-TOKEN": token, "Accept": "application/json", "User-Agent": "MAIPA-G"]
    }

    static func error(_ response: HTTPResponse) -> GitHubAPIError {
        let json = JSONValue.parse(response.body)
        var message = json?["message"]?.stringValue ?? json?["error_description"]?.stringValue ?? json?["error"]?.stringValue
        if message == nil, let object = json?["message"]?.objectValue {
            message = object.map { key, value in
                key + " " + (value.arrayValue?.compactMap(\.stringValue).joined(separator: ", ") ?? value.stringValue ?? "")
            }.sorted().joined(separator: "; ")
        }
        if message == nil, let list = json?["message"]?.arrayValue { message = list.compactMap(\.stringValue).joined(separator: "; ") }
        let text = (message ?? response.text).trimmingCharacters(in: .whitespacesAndNewlines)
        return GitHubAPIError(status: response.status, message: text.isEmpty ? "HTTP \(response.status)" : String(text.prefix(400)))
    }

    @discardableResult
    func send(_ method: String, _ path: String, query: [String: String] = [:], body: JSONValue? = nil, allow: Set<Int> = []) async throws -> HTTPResponse {
        let url = try url(path, query: query)
        let isRead = method == "GET" || method == "HEAD"
        let encoded = try body.map { try JSONCoding.encoder().encode($0) }
        var headers = headers
        if encoded != nil { headers["Content-Type"] = "application/json" }
        let request = HTTPRequest(method: method, url: url, headers: headers, body: encoded, idleTimeout: 60)
        let response = try await withRetries(isRead ? .standard : .none, retryAfter: defaultRetryDelay) {
            let response = try await transport.send(request)
            if isRead, [502, 503, 504].contains(response.status) {
                throw HTTPError.status(code: response.status, body: response.text, headers: response.headers)
            }
            return response
        }
        guard response.isSuccess || allow.contains(response.status) else { throw Self.error(response) }
        return response
    }

    func json(_ method: String, _ path: String, query: [String: String] = [:], body: JSONValue? = nil) async throws -> JSONValue {
        let response = try await send(method, path, query: query, body: body)
        guard let value = JSONValue.parse(response.body) else { throw GitHubAPIError(status: response.status, message: "GitLab sent an unreadable answer.") }
        return value
    }

    /// Every page of a list, up to `maxPages` pages of 100. The second value is false when the
    /// list was cut off.
    func pages(_ path: String, query: [String: String] = [:], maxPages: Int = 20) async throws -> (items: [JSONValue], complete: Bool) {
        var items: [JSONValue] = []
        var page = 1
        while page <= maxPages {
            var q = query
            q["per_page"] = "100"
            q["page"] = String(page)
            let response = try await send("GET", path, query: q)
            let batch = JSONValue.parse(response.body)?.arrayValue ?? []
            items += batch
            let next = response.header("x-next-page")?.trimmingCharacters(in: .whitespaces) ?? ""
            if batch.count < 100 || (response.header("x-next-page") != nil && next.isEmpty) { return (items, true) }
            page = Int(next) ?? page + 1
        }
        return (items, false)
    }

    // MARK: Account and projects

    public struct User: Sendable, Hashable {
        public var id: Int
        public var username: String
        public var name: String?
    }

    public func currentUser() async throws -> User {
        let value = try await json("GET", "/user")
        guard let id = value["id"]?.intValue, let username = value["username"]?.stringValue else {
            throw GitHubAPIError(status: 500, message: "GitLab didn't say who this token belongs to.")
        }
        return User(id: id, username: username, name: value["name"]?.stringValue)
    }

    static func date(_ text: String?) -> Date? {
        guard let text else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    func project(from value: JSONValue) -> GitHubRepo? {
        guard let id = value["id"]?.intValue,
              let full = value["path_with_namespace"]?.stringValue,
              let slash = full.lastIndex(of: "/") else { return nil }
        let owner = value["namespace"]?["full_path"]?.stringValue ?? String(full[..<slash])
        let path = value["path"]?.stringValue ?? String(full[full.index(after: slash)...])
        return GitHubRepo(
            id: id, name: path, fullName: owner + "/" + path, ownerLogin: owner,
            isPrivate: (value["visibility"]?.stringValue ?? "private") != "public",
            summary: value["description"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 },
            defaultBranch: value["default_branch"]?.stringValue ?? "main",
            pushedAt: Self.date(value["last_activity_at"]?.stringValue),
            isFork: value["forked_from_project"]?.objectValue != nil,
            isArchived: value["archived"]?.boolValue ?? false,
            htmlURL: value["web_url"]?.stringValue ?? "https://\(host)/\(full)",
            host: host
        )
    }

    /// The projects the token's user is a member of, most recently active first.
    public func projects() async throws -> [GitHubRepo] {
        let (items, _) = try await pages("/projects", query: ["membership": "true", "order_by": "last_activity_at", "sort": "desc"], maxPages: 5)
        return items.compactMap(project(from:))
    }

    public func repository(_ repo: RepoRef) async throws -> GitHubRepo {
        guard let project = project(from: try await json("GET", "/projects/\(Self.projectID(repo))")) else {
            throw GitHubAPIError(status: 404, message: "GitLab project \(repo.fullName) wasn't found.")
        }
        return project
    }

    public func repositoryIfExists(_ repo: RepoRef) async throws -> GitHubRepo? {
        let response = try await send("GET", "/projects/\(Self.projectID(repo))", allow: [404])
        guard response.status != 404, let value = JSONValue.parse(response.body) else { return nil }
        return project(from: value)
    }

    // MARK: Reading

    public func branches(_ repo: RepoRef) async throws -> [GitHubBranch] {
        let (items, _) = try await pages("/projects/\(Self.projectID(repo))/repository/branches", maxPages: 10)
        return items.compactMap { item in
            guard let name = item["name"]?.stringValue, let sha = item["commit"]?["id"]?.stringValue else { return nil }
            return GitHubBranch(name: name, commitSHA: sha, isProtected: item["protected"]?.boolValue ?? false)
        }
    }

    public func resolveCommit(_ repo: RepoRef, ref: String) async throws -> String {
        let value = try await json("GET", "/projects/\(Self.projectID(repo))/repository/commits/\(Self.escape(ref))")
        guard let sha = value["id"]?.stringValue else { throw GitHubAPIError(status: 404, message: "GitLab has no commit for \(ref).") }
        return sha
    }

    public func branchHead(_ repo: RepoRef, branch: String) async throws -> String? {
        let response = try await send("GET", "/projects/\(Self.projectID(repo))/repository/branches/\(Self.escape(branch))", allow: [404])
        guard response.status != 404 else { return nil }
        return JSONValue.parse(response.body)?["commit"]?["id"]?.stringValue
    }

    /// Every file and folder at `sha`. GitLab gives no sizes in a listing.
    public func tree(_ repo: RepoRef, sha: String, recursive: Bool = true) async throws -> GitTree {
        let (items, complete) = try await pages(
            "/projects/\(Self.projectID(repo))/repository/tree",
            query: ["ref": sha, "recursive": recursive ? "true" : "false"],
            maxPages: 1000
        )
        let entries = items.compactMap { item -> GitTreeEntry? in
            guard let path = item["path"]?.stringValue, let type = item["type"]?.stringValue, let id = item["id"]?.stringValue else { return nil }
            return GitTreeEntry(path: path, mode: item["mode"]?.stringValue ?? (type == "tree" ? "040000" : "100644"), type: type, sha: id)
        }
        return GitTree(sha: sha, entries: entries, truncated: !complete)
    }

    public func blob(_ repo: RepoRef, sha: String) async throws -> Data {
        try await send("GET", "/projects/\(Self.projectID(repo))/repository/blobs/\(Self.escape(sha))/raw").body
    }

    public func fileContents(_ repo: RepoRef, path: String, ref: String) async throws -> Data {
        try await send("GET", "/projects/\(Self.projectID(repo))/repository/files/\(Self.escape(path))/raw", query: ["ref": ref]).body
    }

    /// The real file behind a Git LFS pointer, through GitLab's LFS server.
    public func lfsObject(_ repo: RepoRef, pointer: GitLFSPointer) async throws -> Data {
        let credential = Data("oauth2:\(token)".utf8).base64EncodedString()
        let path = (repo.owner + "/" + repo.name).split(separator: "/").map { Self.escape(String($0)) }.joined(separator: "/")
        guard let batchURL = URL(string: "https://\(host)/\(path).git/info/lfs/objects/batch") else { throw GitLFSError.badResponse }
        let body: JSONValue = ["operation": "download", "transfers": ["basic"], "objects": [["oid": .string(pointer.oid), "size": .number(Double(pointer.size))]]]
        let batch = try await transport.send(HTTPRequest(
            method: "POST", url: batchURL,
            headers: ["Accept": "application/vnd.git-lfs+json", "Content-Type": "application/vnd.git-lfs+json", "Authorization": "Basic \(credential)"],
            body: try JSONCoding.encoder().encode(body), idleTimeout: 60, followsRedirects: false
        ))
        guard batch.isSuccess, let answer = JSONValue.parse(batch.body), let object = answer["objects"]?.arrayValue?.first else {
            throw GitLFSError.unavailable(batch.status)
        }
        if let message = object["error"]?["message"]?.stringValue { throw GitLFSError.refused(message) }
        guard let href = object["actions"]?["download"]?["href"]?.stringValue, let url = URL(string: href), url.scheme == "https" else {
            throw GitLFSError.badResponse
        }
        var headers: [String: String] = [:]
        for (key, value) in object["actions"]?["download"]?["header"]?.objectValue ?? [:] {
            if let text = value.stringValue { headers[key] = text }
        }
        let download = try await transport.send(HTTPRequest(method: "GET", url: url, headers: headers, body: nil, idleTimeout: 120))
        guard download.isSuccess else { throw GitLFSError.unavailable(download.status) }
        guard download.body.count == pointer.size, Hashing.sha256Hex(download.body) == pointer.oid else { throw GitLFSError.checksumMismatch }
        return download.body
    }

    public func downloadTarball(_ repo: RepoRef, ref: String, to destination: URL, progress: (@Sendable (Int64) -> Void)? = nil) async throws {
        let request = HTTPRequest(
            url: try url("/projects/\(Self.projectID(repo))/repository/archive.tar.gz", query: ["sha": ref]),
            headers: headers, idleTimeout: 120
        )
        let response = try await withRetries(.standard, retryAfter: defaultRetryDelay) {
            let response = try await transport.download(request, to: destination, progress: progress)
            if [502, 503, 504].contains(response.status) {
                throw HTTPError.status(code: response.status, body: response.text, headers: response.headers)
            }
            return response
        }
        guard response.isSuccess else { throw Self.error(response) }
    }

    /// GitLab's comparison lists changed files without their new blob ids, so it is reported as
    /// "diverged" unless nothing changed: a snapshot then downloads afresh instead of patching.
    public func compare(_ repo: RepoRef, base: String, head: String) async throws -> GitCompare {
        let value = try await json("GET", "/projects/\(Self.projectID(repo))/repository/compare", query: ["from": base, "to": head])
        let diffs = value["diffs"]?.arrayValue ?? []
        let files = diffs.compactMap { diff -> GitCompare.File? in
            guard let path = diff["new_path"]?.stringValue else { return nil }
            let status = diff["new_file"]?.boolValue == true ? "added"
                : diff["deleted_file"]?.boolValue == true ? "removed"
                : diff["renamed_file"]?.boolValue == true ? "renamed" : "modified"
            let old = diff["old_path"]?.stringValue
            return GitCompare.File(path: path, status: status, sha: nil, previousPath: old == path ? nil : old, patch: diff["diff"]?.stringValue)
        }
        let commits = value["commits"]?.arrayValue?.count ?? 0
        return GitCompare(
            status: files.isEmpty && commits == 0 ? "identical" : "diverged",
            aheadBy: commits, behindBy: 0, files: files,
            isComplete: !(value["overflow"]?.boolValue ?? false)
        )
    }

    // MARK: Saving

    public func createBranch(_ repo: RepoRef, branch: String, from sha: String) async throws {
        try await send("POST", "/projects/\(Self.projectID(repo))/repository/branches", query: ["branch": branch, "ref": sha])
    }

    public func deleteBranchIfMAIPAG(_ repo: RepoRef, branch: String) async throws {
        guard GitHubClient.isMAIPAGBranch(branch) else { return }
        try await send("DELETE", "/projects/\(Self.projectID(repo))/repository/branches/\(Self.escape(branch))", allow: [404])
    }

    /// One file change in a commit. `contents == nil` deletes the file; `existed` says whether it
    /// was there before (GitLab wants "create" and "update" told apart).
    public struct FileAction: Sendable, Hashable {
        public var path: String
        public var contents: Data?
        public var existed: Bool
        public init(path: String, contents: Data?, existed: Bool) {
            self.path = path; self.contents = contents; self.existed = existed
        }

        var json: JSONValue {
            guard let contents else { return ["action": "delete", "file_path": .string(path)] }
            return [
                "action": .string(existed ? "update" : "create"),
                "file_path": .string(path),
                "content": .string(contents.base64EncodedString()),
                "encoding": "base64",
            ]
        }
    }

    /// Commits `actions` on top of `branch` and returns the new commit's id.
    public func commit(_ repo: RepoRef, branch: String, message: String, actions: [FileAction]) async throws -> String {
        let body: JSONValue = [
            "branch": .string(branch),
            "commit_message": .string(message),
            "actions": .array(actions.map(\.json)),
        ]
        let value = try await json("POST", "/projects/\(Self.projectID(repo))/repository/commits", body: body)
        guard let sha = value["id"]?.stringValue else { throw GitHubAPIError(status: 500, message: "GitLab didn't return the new commit.") }
        return sha
    }

    // MARK: Merge requests (shown as pull requests)

    func mergeRequest(from value: JSONValue) throws -> GitHubPullRequest {
        guard let iid = value["iid"]?.intValue else { throw GitHubAPIError(status: 500, message: "GitLab sent an unreadable merge request.") }
        let state = value["state"]?.stringValue ?? "opened"
        return GitHubPullRequest(
            number: iid, title: value["title"]?.stringValue ?? "",
            state: state == "opened" || state == "locked" ? "open" : "closed",
            htmlURL: value["web_url"]?.stringValue ?? "https://\(host)",
            headBranch: value["source_branch"]?.stringValue ?? "",
            baseBranch: value["target_branch"]?.stringValue ?? "",
            isMerged: state == "merged"
        )
    }

    public func openOrReuseMergeRequest(_ repo: RepoRef, title: String, body text: String, head: String, base: String) async throws -> GitHubPullRequest {
        let existing = try await json("GET", "/projects/\(Self.projectID(repo))/merge_requests", query: ["state": "opened", "source_branch": head, "target_branch": base])
        if let open = existing.arrayValue?.first { return try mergeRequest(from: open) }
        let body: JSONValue = [
            "source_branch": .string(head), "target_branch": .string(base),
            "title": .string(title), "description": .string(text),
            "remove_source_branch": .bool(GitHubClient.isMAIPAGBranch(head)),
        ]
        return try mergeRequest(from: try await json("POST", "/projects/\(Self.projectID(repo))/merge_requests", body: body))
    }

    public func mergeRequest(_ repo: RepoRef, number: Int) async throws -> GitHubPullRequest {
        try mergeRequest(from: try await json("GET", "/projects/\(Self.projectID(repo))/merge_requests/\(number)"))
    }

    @discardableResult
    public func closeMergeRequest(_ repo: RepoRef, number: Int) async throws -> GitHubPullRequest {
        try mergeRequest(from: try await json("PUT", "/projects/\(Self.projectID(repo))/merge_requests/\(number)", body: ["state_event": "close"]))
    }

    public func merge(_ repo: RepoRef, number: Int, title: String) async throws {
        try await send("PUT", "/projects/\(Self.projectID(repo))/merge_requests/\(number)/merge", body: ["squash": true, "squash_commit_message": .string(title)])
    }

    /// The newest pipeline for a commit: "success", "failed", "running"…, or nil when there is none.
    public func pipelineStatus(_ repo: RepoRef, commit: String) async throws -> String? {
        let value = try await json("GET", "/projects/\(Self.projectID(repo))/pipelines", query: ["sha": commit, "per_page": "1", "order_by": "id", "sort": "desc"])
        return value.arrayValue?.first?["status"]?.stringValue
    }
}
