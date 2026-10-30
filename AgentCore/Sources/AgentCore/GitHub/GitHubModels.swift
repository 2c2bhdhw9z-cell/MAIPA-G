import Foundation

/// "owner/name" for a repository.
public struct RepoRef: Codable, Sendable, Hashable, CustomStringConvertible {
    public var owner: String
    public var name: String

    public init(owner: String, name: String) {
        self.owner = owner
        self.name = name
    }

    public init?(fullName: String) {
        let parts = fullName.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        self.init(owner: parts[0], name: parts[1])
    }

    public var fullName: String { "\(owner)/\(name)" }
    public var description: String { fullName }
    public var webURL: URL { URL(string: "https://github.com/\(owner)/\(name)")! }
}

public struct GitHubUser: Codable, Sendable, Hashable {
    public var id: Int
    public var login: String
    public var name: String?
    public var avatarURL: String?
    /// The account's plan, returned for the signed-in user ("free", "pro"…).
    public var plan: Plan?

    public struct Plan: Codable, Sendable, Hashable {
        public var name: String?
    }

    enum CodingKeys: String, CodingKey {
        case id, login, name, plan
        case avatarURL = "avatar_url"
    }
}

public struct GitHubRepo: Codable, Sendable, Hashable, Identifiable {
    public var id: Int
    public var name: String
    public var fullName: String
    public var ownerLogin: String
    public var isPrivate: Bool
    public var summary: String?
    public var defaultBranch: String
    public var pushedAt: Date?
    public var language: String?
    /// Kilobytes, including history. A rough upper bound for how big a download of it is.
    public var sizeKB: Int?
    public var isFork: Bool
    public var isArchived: Bool
    public var htmlURL: String

    public var ref: RepoRef { RepoRef(owner: ownerLogin, name: name) }

    enum CodingKeys: String, CodingKey {
        case id, name, language, owner, size, fork, archived
        case fullName = "full_name"
        case isPrivate = "private"
        case summary = "description"
        case defaultBranch = "default_branch"
        case pushedAt = "pushed_at"
        case htmlURL = "html_url"
    }

    struct Owner: Codable { let login: String }

    public init(
        id: Int, name: String, fullName: String, ownerLogin: String, isPrivate: Bool, summary: String? = nil,
        defaultBranch: String, pushedAt: Date? = nil, language: String? = nil, sizeKB: Int? = nil,
        isFork: Bool = false, isArchived: Bool = false, htmlURL: String
    ) {
        self.id = id
        self.name = name
        self.fullName = fullName
        self.ownerLogin = ownerLogin
        self.isPrivate = isPrivate
        self.summary = summary
        self.defaultBranch = defaultBranch
        self.pushedAt = pushedAt
        self.language = language
        self.sizeKB = sizeKB
        self.isFork = isFork
        self.isArchived = isArchived
        self.htmlURL = htmlURL
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        fullName = try c.decode(String.self, forKey: .fullName)
        ownerLogin = try c.decode(Owner.self, forKey: .owner).login
        isPrivate = try c.decodeIfPresent(Bool.self, forKey: .isPrivate) ?? false
        summary = try c.decodeIfPresent(String.self, forKey: .summary)
        defaultBranch = try c.decodeIfPresent(String.self, forKey: .defaultBranch) ?? "main"
        pushedAt = try c.decodeIfPresent(Date.self, forKey: .pushedAt)
        language = try c.decodeIfPresent(String.self, forKey: .language)
        sizeKB = try c.decodeIfPresent(Int.self, forKey: .size)
        isFork = try c.decodeIfPresent(Bool.self, forKey: .fork) ?? false
        isArchived = try c.decodeIfPresent(Bool.self, forKey: .archived) ?? false
        htmlURL = try c.decode(String.self, forKey: .htmlURL)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(fullName, forKey: .fullName)
        try c.encode(Owner(login: ownerLogin), forKey: .owner)
        try c.encode(isPrivate, forKey: .isPrivate)
        try c.encodeIfPresent(summary, forKey: .summary)
        try c.encode(defaultBranch, forKey: .defaultBranch)
        try c.encodeIfPresent(pushedAt, forKey: .pushedAt)
        try c.encodeIfPresent(language, forKey: .language)
        try c.encodeIfPresent(sizeKB, forKey: .size)
        try c.encode(isFork, forKey: .fork)
        try c.encode(isArchived, forKey: .archived)
        try c.encode(htmlURL, forKey: .htmlURL)
    }
}

public struct GitHubBranch: Codable, Sendable, Hashable, Identifiable {
    public var name: String
    public var commitSHA: String
    public var isProtected: Bool

    public var id: String { name }

    public init(name: String, commitSHA: String, isProtected: Bool = false) {
        self.name = name
        self.commitSHA = commitSHA
        self.isProtected = isProtected
    }

    enum CodingKeys: String, CodingKey { case name, commit, protected }
    struct Commit: Codable { let sha: String }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        commitSHA = try c.decode(Commit.self, forKey: .commit).sha
        isProtected = try c.decodeIfPresent(Bool.self, forKey: .protected) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(Commit(sha: commitSHA), forKey: .commit)
        try c.encode(isProtected, forKey: .protected)
    }
}

/// One entry of a Git tree: a file ("blob"), a folder ("tree") or a submodule ("commit").
public struct GitTreeEntry: Codable, Sendable, Hashable {
    public var path: String
    public var mode: String
    public var type: String
    public var sha: String
    public var size: Int?

    public init(path: String, mode: String, type: String, sha: String, size: Int? = nil) {
        self.path = path
        self.mode = mode
        self.type = type
        self.sha = sha
        self.size = size
    }

    public var isFile: Bool { type == "blob" }
    public var isFolder: Bool { type == "tree" }
    public var isSymlink: Bool { mode == "120000" }
}

public struct GitTree: Codable, Sendable, Hashable {
    public var sha: String
    public var entries: [GitTreeEntry]
    /// GitHub stops listing at 100,000 entries or 7 MB; the listing is then incomplete.
    public var truncated: Bool

    enum CodingKeys: String, CodingKey {
        case sha, truncated
        case entries = "tree"
    }

    public init(sha: String, entries: [GitTreeEntry], truncated: Bool) {
        self.sha = sha
        self.entries = entries
        self.truncated = truncated
    }
}

/// The files that differ between two commits (GET /repos/{o}/{r}/compare/{base}...{head}).
public struct GitCompare: Sendable, Hashable {
    public struct File: Sendable, Hashable {
        public var path: String
        public var status: String
        public var sha: String?
        public var previousPath: String?
        public var patch: String?
    }

    public var status: String
    public var aheadBy: Int
    public var behindBy: Int
    public var files: [File]
    /// GitHub lists at most 300 files per comparison.
    public var isComplete: Bool
}

/// Where MAIPA-G's GitHub app is installed.
public struct GitHubInstallation: Codable, Sendable, Hashable, Identifiable {
    public var id: Int
    public var appID: Int
    public var appSlug: String
    public var accountLogin: String
    public var accountType: String
    /// "all" or "selected".
    public var repositorySelection: String

    enum CodingKeys: String, CodingKey {
        case id, account
        case appID = "app_id"
        case appSlug = "app_slug"
        case repositorySelection = "repository_selection"
    }

    struct Account: Codable {
        let login: String
        let type: String?
    }

    public init(id: Int, appID: Int, appSlug: String, accountLogin: String, accountType: String = "User", repositorySelection: String = "all") {
        self.id = id
        self.appID = appID
        self.appSlug = appSlug
        self.accountLogin = accountLogin
        self.accountType = accountType
        self.repositorySelection = repositorySelection
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        appID = try c.decode(Int.self, forKey: .appID)
        appSlug = try c.decodeIfPresent(String.self, forKey: .appSlug) ?? ""
        let account = try c.decode(Account.self, forKey: .account)
        accountLogin = account.login
        accountType = account.type ?? "User"
        repositorySelection = try c.decodeIfPresent(String.self, forKey: .repositorySelection) ?? "all"
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(appID, forKey: .appID)
        try c.encode(appSlug, forKey: .appSlug)
        try c.encode(Account(login: accountLogin, type: accountType), forKey: .account)
        try c.encode(repositorySelection, forKey: .repositorySelection)
    }

    /// GitHub's page where the user picks which repos the app may use.
    public var settingsURL: URL { URL(string: "https://github.com/settings/installations/\(id)")! }
}

/// The user's own GitHub app, made for them by the manifest flow. The private key never leaves
/// the phone's Keychain.
public struct GitHubAppCredentials: Codable, Sendable, Hashable {
    public var appID: Int
    public var slug: String
    public var name: String
    public var clientID: String
    public var clientSecret: String
    public var privateKeyPEM: String
    public var ownerLogin: String
    public var htmlURL: String

    public init(appID: Int, slug: String, name: String, clientID: String, clientSecret: String, privateKeyPEM: String, ownerLogin: String, htmlURL: String) {
        self.appID = appID
        self.slug = slug
        self.name = name
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.privateKeyPEM = privateKeyPEM
        self.ownerLogin = ownerLogin
        self.htmlURL = htmlURL
    }

    /// The app's settings page on GitHub.
    public var settingsURL: URL { URL(string: "https://github.com/settings/apps/\(slug)")! }
    /// The name its commits and pull requests show under.
    public var botName: String { "\(slug)[bot]" }
}

/// A token that acts as the user (for creating repos), with what is needed to renew it.
public struct GitHubUserToken: Codable, Sendable, Hashable {
    public var accessToken: String
    public var expiresAt: Date?
    public var refreshToken: String?
    public var refreshTokenExpiresAt: Date?

    public init(accessToken: String, expiresAt: Date?, refreshToken: String?, refreshTokenExpiresAt: Date?) {
        self.accessToken = accessToken
        self.expiresAt = expiresAt
        self.refreshToken = refreshToken
        self.refreshTokenExpiresAt = refreshTokenExpiresAt
    }

    public func isFresh(at now: Date = Date(), margin: TimeInterval = 120) -> Bool {
        guard let expiresAt else { return true }
        return expiresAt.timeIntervalSince(now) > margin
    }

    public func canRefresh(at now: Date = Date()) -> Bool {
        guard refreshToken != nil else { return false }
        guard let refreshTokenExpiresAt else { return true }
        return refreshTokenExpiresAt > now
    }
}

public struct GitHubPullRequest: Codable, Sendable, Hashable, Identifiable {
    public var number: Int
    public var title: String
    public var state: String
    public var htmlURL: String
    public var headBranch: String
    public var baseBranch: String
    public var isMerged: Bool
    public var id: Int { number }

    enum CodingKeys: String, CodingKey { case number, title, state, head, base, merged; case htmlURL = "html_url" }
    struct RefValue: Codable { var ref: String }

    public init(number: Int, title: String, state: String = "open", htmlURL: String, headBranch: String, baseBranch: String, isMerged: Bool = false) {
        self.number = number; self.title = title; self.state = state; self.htmlURL = htmlURL
        self.headBranch = headBranch; self.baseBranch = baseBranch; self.isMerged = isMerged
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        number = try c.decode(Int.self, forKey: .number)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "Changes from MAIPA-G"
        state = try c.decodeIfPresent(String.self, forKey: .state) ?? "open"
        htmlURL = try c.decodeIfPresent(String.self, forKey: .htmlURL) ?? ""
        headBranch = try c.decodeIfPresent(RefValue.self, forKey: .head)?.ref ?? ""
        baseBranch = try c.decodeIfPresent(RefValue.self, forKey: .base)?.ref ?? "main"
        isMerged = try c.decodeIfPresent(Bool.self, forKey: .merged) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(number, forKey: .number); try c.encode(title, forKey: .title); try c.encode(state, forKey: .state)
        try c.encode(htmlURL, forKey: .htmlURL); try c.encode(RefValue(ref: headBranch), forKey: .head)
        try c.encode(RefValue(ref: baseBranch), forKey: .base); try c.encode(isMerged, forKey: .merged)
    }
}

/// A published MAIPA-G build, for "a new build is out".
public struct GitHubRelease: Codable, Sendable, Hashable {
    public var tagName: String
    public var name: String?
    public var htmlURL: String
    public var publishedAt: Date?
    public var assets: [Asset]

    public struct Asset: Codable, Sendable, Hashable {
        public var name: String
        public var downloadURL: String
        enum CodingKeys: String, CodingKey {
            case name
            case downloadURL = "browser_download_url"
        }
    }

    enum CodingKeys: String, CodingKey {
        case name, assets
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case publishedAt = "published_at"
    }

    /// The run number in a tag like "build-12-abc1234".
    public var buildNumber: Int? {
        let parts = tagName.split(separator: "-")
        guard parts.count >= 2, parts[0] == "build" else { return nil }
        return Int(parts[1])
    }
}

public struct GitHubWorkflowRun: Codable, Sendable, Hashable, Identifiable {
    public var id: Int
    public var name: String
    public var status: String
    public var conclusion: String?
    public var event: String
    public var headBranch: String?
    public var headSHA: String
    public var htmlURL: String
    public var runNumber: Int
    public var createdAt: Date
    public var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, name, status, conclusion, event
        case headBranch = "head_branch"
        case headSHA = "head_sha"
        case htmlURL = "html_url"
        case runNumber = "run_number"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

public struct GitHubWorkflowJob: Codable, Sendable, Hashable, Identifiable {
    public struct Step: Codable, Sendable, Hashable {
        public var name: String
        public var status: String
        public var conclusion: String?
        public var number: Int
    }
    public var id: Int
    public var name: String
    public var status: String
    public var conclusion: String?
    public var htmlURL: String
    public var steps: [Step]

    enum CodingKeys: String, CodingKey {
        case id, name, status, conclusion, steps
        case htmlURL = "html_url"
    }
}

public struct GitHubArtifact: Codable, Sendable, Hashable, Identifiable {
    public var id: Int
    public var name: String
    public var sizeInBytes: Int
    public var archiveDownloadURL: String
    public var expired: Bool
    public var createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, name, expired
        case sizeInBytes = "size_in_bytes"
        case archiveDownloadURL = "archive_download_url"
        case createdAt = "created_at"
    }
}

public struct GitHubCheckRun: Codable, Sendable, Hashable, Identifiable {
    public var id: Int
    public var name: String
    public var status: String
    public var conclusion: String?
    public var htmlURL: String?
    enum CodingKeys: String, CodingKey { case id, name, status, conclusion; case htmlURL = "html_url" }
}

public struct GitHubCommitStatus: Codable, Sendable, Hashable, Identifiable {
    public var id: Int
    public var state: String
    public var context: String
    public var description: String?
    public var targetURL: String?
    enum CodingKeys: String, CodingKey { case id, state, context, description; case targetURL = "target_url" }
}

public struct GitHubActionsPublicKey: Codable, Sendable, Hashable {
    public var keyID: String
    public var key: String
    enum CodingKeys: String, CodingKey { case keyID = "key_id"; case key }
}
