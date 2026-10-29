import Foundation

/// An error from GitHub's API, with the parts the app needs to explain it.
public struct GitHubAPIError: Error, Sendable, Hashable, CustomStringConvertible {
    public var status: Int
    public var message: String
    /// When the hourly request allowance comes back, if that is what ran out.
    public var rateLimitResetsAt: Date?

    public init(status: Int, message: String, rateLimitResetsAt: Date? = nil) {
        self.status = status
        self.message = message
        self.rateLimitResetsAt = rateLimitResetsAt
    }

    init(response: HTTPResponse) {
        let json = JSONValue.parse(response.body)
        var message = json?["message"]?.stringValue ?? response.text
        if let errors = json?["errors"]?.arrayValue, !errors.isEmpty {
            let details = errors.compactMap { $0["message"]?.stringValue ?? $0["code"]?.stringValue }
            if !details.isEmpty { message += " (" + details.joined(separator: "; ") + ")" }
        }
        var resetsAt: Date?
        if response.header("x-ratelimit-remaining") == "0", let reset = response.header("x-ratelimit-reset").flatMap(Double.init) {
            resetsAt = Date(timeIntervalSince1970: reset)
        }
        self.init(status: response.status, message: message.isEmpty ? "HTTP \(response.status)" : message, rateLimitResetsAt: resetsAt)
    }

    public var isNotFound: Bool { status == 404 }
    public var isUnauthorized: Bool { status == 401 }
    public var isRateLimited: Bool { rateLimitResetsAt != nil || ((status == 403 || status == 429) && message.lowercased().contains("rate limit")) }
    public var description: String { "GitHub \(status): \(message)" }
}

/// Supplies the two kinds of GitHub token MAIPA-G uses.
public protocol GitHubTokenProvider: Sendable {
    /// Acts as MAIPA-G's own app (the bot), for everything inside repos.
    func installationToken() async throws -> String
    /// Acts as the user, for the few things an app cannot do alone, like creating a repo.
    func userToken() async throws -> String
}

/// GitHub's REST API, as MAIPA-G uses it.
public struct GitHubClient: Sendable {
    public static let api = URL(string: "https://api.github.com")!
    public static let apiVersion = "2026-03-10"

    public enum Auth: Sendable {
        case installation, user, none
        case bearer(String)
    }

    private let transport: any HTTPTransport
    private let tokens: (any GitHubTokenProvider)?

    public init(transport: any HTTPTransport, tokens: (any GitHubTokenProvider)?) {
        self.transport = transport
        self.tokens = tokens
    }

    // MARK: Plumbing

    func url(_ path: String, query: [String: String] = [:]) -> URL {
        var components = URLComponents(url: Self.api, resolvingAgainstBaseURL: false)!
        components.percentEncodedPath = path.hasPrefix("/") ? path : "/" + path
        if !query.isEmpty {
            components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        return components.url!
    }

    func headers(_ auth: Auth, accept: String) async throws -> [String: String] {
        var headers = [
            "Accept": accept,
            "X-GitHub-Api-Version": Self.apiVersion,
            "User-Agent": "MAIPA-G",
        ]
        switch auth {
        case .none: break
        case .bearer(let token): headers["Authorization"] = "Bearer \(token)"
        case .installation:
            guard let tokens else { throw GitHubAPIError(status: 401, message: "GitHub is not connected") }
            headers["Authorization"] = "Bearer \(try await tokens.installationToken())"
        case .user:
            guard let tokens else { throw GitHubAPIError(status: 401, message: "GitHub is not connected") }
            headers["Authorization"] = "Bearer \(try await tokens.userToken())"
        }
        return headers
    }

    /// Sends a request. Reads are retried on temporary failures; writes are sent once.
    public func send(
        _ method: String,
        _ path: String,
        query: [String: String] = [:],
        body: JSONValue? = nil,
        auth: Auth = .installation,
        accept: String = "application/vnd.github+json",
        allow: Set<Int> = []
    ) async throws -> HTTPResponse {
        let url = url(path, query: query)
        let isRead = method == "GET" || method == "HEAD"
        let encodedBody = try body.map { try JSONCoding.encoder().encode($0) }
        let response = try await withRetries(isRead ? .standard : .none, retryAfter: defaultRetryDelay) {
            var headers = try await headers(auth, accept: accept)
            if encodedBody != nil { headers["Content-Type"] = "application/json" }
            let response = try await transport.send(HTTPRequest(method: method, url: url, headers: headers, body: encodedBody, idleTimeout: 60))
            if isRead, [502, 503, 504].contains(response.status) {
                throw HTTPError.status(code: response.status, body: response.text, headers: response.headers)
            }
            return response
        }
        guard response.isSuccess || allow.contains(response.status) else { throw GitHubAPIError(response: response) }
        return response
    }

    func get<T: Decodable>(_ type: T.Type, _ path: String, query: [String: String] = [:], auth: Auth = .installation) async throws -> T {
        try await send("GET", path, query: query, auth: auth).decode(type)
    }

    /// Follows GitHub's `Link: <…>; rel="next"` pages. `key` names the array inside an object
    /// response (as in /installation/repositories); nil means the response is the array.
    func paginate<T: Decodable & Sendable>(_ type: T.Type, _ path: String, key: String? = nil, query: [String: String] = [:], auth: Auth = .installation, limit: Int = 5_000) async throws -> [T] {
        var results: [T] = []
        var query = query
        query["per_page"] = "100"
        var next: URL? = url(path, query: query)
        while let page = next, results.count < limit {
            let response = try await withRetries(.standard, retryAfter: defaultRetryDelay) {
                let headers = try await headers(auth, accept: "application/vnd.github+json")
                return try await transport.send(HTTPRequest(url: page, headers: headers))
            }
            guard response.isSuccess else { throw GitHubAPIError(response: response) }
            if let key {
                let decoder = JSONCoding.decoder()
                decoder.userInfo[.paginationKey] = key
                do {
                    results += try decoder.decode(KeyedPage<T>.self, from: response.body).items
                } catch {
                    throw HTTPError.undecodable(status: response.status, type: "\(T.self) page", detail: "\(error)", body: response.text)
                }
            } else {
                results += try response.decode([T].self)
            }
            next = Self.nextPage(from: response.header("link"))
        }
        return results
    }

    static func nextPage(from link: String?) -> URL? {
        guard let link else { return nil }
        for part in link.split(separator: ",") {
            let pieces = part.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            guard pieces.count >= 2, pieces.dropFirst().contains(where: { $0 == "rel=\"next\"" }) else { continue }
            let target = pieces[0].trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
            return URL(string: target)
        }
        return nil
    }

    static func path(_ repo: RepoRef, _ rest: String = "") -> String {
        "/repos/\(escape(repo.owner))/\(escape(repo.name))" + rest
    }

    /// Escapes one path segment.
    static func escape(_ segment: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#")
        return segment.addingPercentEncoding(withAllowedCharacters: allowed) ?? segment
    }

    /// Escapes a file path, keeping its slashes.
    static func escapePath(_ path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: false).map { escape(String($0)) }.joined(separator: "/")
    }

    // MARK: Repos and branches

    /// Every repo MAIPA-G's app can reach, most recently pushed first.
    public func installationRepositories() async throws -> [GitHubRepo] {
        let repos = try await paginate(GitHubRepo.self, "/installation/repositories", key: "repositories")
        return repos.sorted { ($0.pushedAt ?? .distantPast) > ($1.pushedAt ?? .distantPast) }
    }

    public func repository(_ repo: RepoRef, auth: Auth = .installation) async throws -> GitHubRepo {
        try await get(GitHubRepo.self, Self.path(repo), auth: auth)
    }

    /// nil when the repo does not exist (or MAIPA-G cannot see it).
    public func repositoryIfExists(_ repo: RepoRef, auth: Auth = .installation) async throws -> GitHubRepo? {
        let response = try await send("GET", Self.path(repo), auth: auth, allow: [404])
        return response.status == 404 ? nil : try response.decode(GitHubRepo.self)
    }

    public func branches(_ repo: RepoRef) async throws -> [GitHubBranch] {
        try await paginate(GitHubBranch.self, Self.path(repo, "/branches"))
    }

    /// The commit a branch (or any ref) points at, as a 40-character id.
    public func resolveCommit(_ repo: RepoRef, ref: String) async throws -> String {
        let response = try await send("GET", Self.path(repo, "/commits/\(Self.escapePath(ref))"), accept: "application/vnd.github.sha")
        let sha = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard sha.count == 40 || sha.count == 64 else { throw GitHubAPIError(status: response.status, message: "Unexpected commit id \(sha.prefix(80))") }
        return sha
    }

    public func tree(_ repo: RepoRef, sha: String, recursive: Bool = true) async throws -> GitTree {
        try await get(GitTree.self, Self.path(repo, "/git/trees/\(sha)"), query: recursive ? ["recursive": "1"] : [:])
    }

    /// A file's bytes by its blob id.
    public func blob(_ repo: RepoRef, sha: String) async throws -> Data {
        try await send("GET", Self.path(repo, "/git/blobs/\(sha)"), accept: "application/vnd.github.raw+json").body
    }

    /// A file's bytes at a commit or branch.
    public func fileContents(_ repo: RepoRef, path: String, ref: String) async throws -> Data {
        try await send("GET", Self.path(repo, "/contents/\(Self.escapePath(path))"), query: ["ref": ref], accept: "application/vnd.github.raw+json").body
    }

    /// Downloads the whole repo at `ref` as a gzip'd tarball, straight to a file.
    public func downloadTarball(_ repo: RepoRef, ref: String, to destination: URL, progress: (@Sendable (Int64) -> Void)? = nil) async throws {
        let headers = try await headers(.installation, accept: "application/vnd.github+json")
        let request = HTTPRequest(url: url(Self.path(repo, "/tarball/\(Self.escapePath(ref))")), headers: headers, idleTimeout: 120)
        let response = try await withRetries(.standard, retryAfter: defaultRetryDelay) {
            let response = try await transport.download(request, to: destination, progress: progress)
            if [502, 503, 504].contains(response.status) {
                throw HTTPError.status(code: response.status, body: response.text, headers: response.headers)
            }
            return response
        }
        guard response.isSuccess else { throw GitHubAPIError(response: response) }
    }

    public func compare(_ repo: RepoRef, base: String, head: String) async throws -> GitCompare {
        let response = try await send("GET", Self.path(repo, "/compare/\(base)...\(head)"), query: ["per_page": "300"])
        guard let json = JSONValue.parse(response.body) else { throw GitHubAPIError(status: response.status, message: "Unreadable comparison") }
        let files = (json["files"]?.arrayValue ?? []).compactMap { file -> GitCompare.File? in
            guard let path = file["filename"]?.stringValue, let status = file["status"]?.stringValue else { return nil }
            return GitCompare.File(path: path, status: status, sha: file["sha"]?.stringValue, previousPath: file["previous_filename"]?.stringValue)
        }
        let changedFiles = json["files"]?.arrayValue?.count ?? 0
        return GitCompare(
            status: json["status"]?.stringValue ?? "unknown",
            aheadBy: json["ahead_by"]?.intValue ?? 0,
            behindBy: json["behind_by"]?.intValue ?? 0,
            files: files,
            isComplete: changedFiles < 300
        )
    }

    // MARK: As the user

    public func authenticatedUser() async throws -> GitHubUser {
        try await get(GitHubUser.self, "/user", auth: .user)
    }

    /// Makes a repo under the user's own account.
    public func createUserRepository(name: String, isPrivate: Bool, description: String, autoInit: Bool) async throws -> GitHubRepo {
        let body: JSONValue = [
            "name": .string(name),
            "private": .bool(isPrivate),
            "description": .string(description),
            "auto_init": .bool(autoInit),
            "has_issues": false,
            "has_projects": false,
            "has_wiki": false,
        ]
        return try await send("POST", "/user/repos", body: body, auth: .user).decode(GitHubRepo.self)
    }

    /// Adds a repo to the app's installation, for when the user only let it into some repos.
    public func addRepositoryToInstallation(installationID: Int, repositoryID: Int) async throws {
        _ = try await send("PUT", "/user/installations/\(installationID)/repositories/\(repositoryID)", auth: .user)
    }

    // MARK: Git data (used to save MAIPA-G's own data)

    /// The commit a branch points at, or nil when the branch (or the whole repo) is empty.
    public func branchHead(_ repo: RepoRef, branch: String) async throws -> String? {
        let response = try await send("GET", Self.path(repo, "/git/ref/heads/\(Self.escapePath(branch))"), allow: [404, 409])
        guard response.isSuccess else { return nil }
        return JSONValue.parse(response.body)?["object"]?["sha"]?.stringValue
    }

    public func commitTree(_ repo: RepoRef, commit: String) async throws -> String {
        let response = try await send("GET", Self.path(repo, "/git/commits/\(commit)"))
        guard let tree = JSONValue.parse(response.body)?["tree"]?["sha"]?.stringValue else {
            throw GitHubAPIError(status: response.status, message: "Commit \(commit.prefix(7)) has no tree")
        }
        return tree
    }

    public func createBlob(_ repo: RepoRef, contents: Data) async throws -> String {
        let body: JSONValue = ["content": .string(contents.base64EncodedString()), "encoding": "base64"]
        let response = try await send("POST", Self.path(repo, "/git/blobs"), body: body)
        guard let sha = JSONValue.parse(response.body)?["sha"]?.stringValue else { throw GitHubAPIError(status: response.status, message: "No blob id") }
        return sha
    }

    /// One change in a new tree: a file's new blob, or nil to delete the file.
    public struct TreeChange: Sendable, Hashable {
        public var path: String
        public var blobSHA: String?
        public init(path: String, blobSHA: String?) {
            self.path = path
            self.blobSHA = blobSHA
        }
    }

    public func createTree(_ repo: RepoRef, base: String?, changes: [TreeChange]) async throws -> String {
        var body: [String: JSONValue] = [
            "tree": .array(changes.map { change in
                [
                    "path": .string(change.path),
                    "mode": "100644",
                    "type": "blob",
                    "sha": change.blobSHA.map(JSONValue.string) ?? .null,
                ]
            }),
        ]
        if let base { body["base_tree"] = .string(base) }
        let response = try await send("POST", Self.path(repo, "/git/trees"), body: .object(body))
        guard let sha = JSONValue.parse(response.body)?["sha"]?.stringValue else { throw GitHubAPIError(status: response.status, message: "No tree id") }
        return sha
    }

    public func createCommit(_ repo: RepoRef, message: String, tree: String, parents: [String]) async throws -> String {
        let body: JSONValue = ["message": .string(message), "tree": .string(tree), "parents": .array(parents.map(JSONValue.string))]
        let response = try await send("POST", Self.path(repo, "/git/commits"), body: body)
        guard let sha = JSONValue.parse(response.body)?["sha"]?.stringValue else { throw GitHubAPIError(status: response.status, message: "No commit id") }
        return sha
    }

    /// Moves a branch to a new commit. Fails with 422 when someone else moved it first, so a save
    /// can never overwrite changes it has not seen.
    public func updateBranch(_ repo: RepoRef, branch: String, to sha: String) async throws {
        _ = try await send("PATCH", Self.path(repo, "/git/refs/heads/\(Self.escapePath(branch))"), body: ["sha": .string(sha), "force": false])
    }

    public func createBranch(_ repo: RepoRef, branch: String, from sha: String) async throws {
        _ = try await send("POST", Self.path(repo, "/git/refs"), body: ["ref": .string("refs/heads/\(branch)"), "sha": .string(sha)])
    }

    public func deleteBranch(_ repo: RepoRef, branch: String) async throws {
        _ = try await send("DELETE", Self.path(repo, "/git/refs/heads/\(Self.escapePath(branch))"), allow: [404])
    }

    public func openPullRequest(_ repo: RepoRef, title: String, body text: String, head: String, base: String) async throws -> GitHubPullRequest {
        let body: JSONValue = ["title": .string(title), "body": .string(text), "head": .string(head), "base": .string(base)]
        return try await send("POST", Self.path(repo, "/pulls"), body: body).decode(GitHubPullRequest.self)
    }

    public func pullRequest(_ repo: RepoRef, number: Int) async throws -> GitHubPullRequest {
        try await get(GitHubPullRequest.self, Self.path(repo, "/pulls/\(number)"))
    }

    public func closePullRequest(_ repo: RepoRef, number: Int) async throws -> GitHubPullRequest {
        try await send("PATCH", Self.path(repo, "/pulls/\(number)"), body: ["state": "closed"]).decode(GitHubPullRequest.self)
    }

    public func mergePullRequest(_ repo: RepoRef, number: Int, title: String) async throws {
        _ = try await send("PUT", Self.path(repo, "/pulls/\(number)/merge"), body: ["merge_method": "squash", "commit_title": .string(title)])
    }

    // MARK: Public

    /// The newest published release of a public repo. Needs no sign-in.
    public func latestRelease(_ repo: RepoRef) async throws -> GitHubRelease? {
        let response = try await send("GET", Self.path(repo, "/releases/latest"), auth: .none, allow: [404])
        return response.status == 404 ? nil : try response.decode(GitHubRelease.self)
    }
}

/// An array inside an object, under the key given in the decoder's user info.
struct KeyedPage<T: Decodable>: Decodable {
    let items: [T]
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyKey.self)
        let key = decoder.userInfo[.paginationKey] as? String ?? ""
        items = try container.decode([T].self, forKey: AnyKey(key))
    }
}

struct AnyKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(_ string: String) { stringValue = string }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

extension CodingUserInfoKey {
    static let paginationKey = CodingUserInfoKey(rawValue: "maipag.paginationKey")!
}
