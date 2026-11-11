import AgentCore
import Foundation
import Observation

/// The user's GitLab connection: gitlab.com or their own server, and a personal access token kept
/// in the Keychain like the GitHub keys. Its projects sit next to GitHub repos in the repo picker
/// and work with the same tools.
@MainActor
@Observable
final class GitLabAccount {
    private(set) var host: String = GitLabClient.defaultHost
    private(set) var user: GitLabClient.User?
    private(set) var repos: [GitHubRepo] = []
    private(set) var isLoadingRepos = false
    private(set) var reposError: String?
    private(set) var isConnecting = false
    private(set) var lastError: String?
    @ObservationIgnored private var token: String?
    @ObservationIgnored private var branchCache: [String: (date: Date, branches: [GitHubBranch])] = [:]

    let transport: any HTTPTransport

    init(transport: any HTTPTransport) {
        self.transport = transport
    }

    var isConnected: Bool { token != nil }
    /// For MAIPA-G's own code copying a private GitLab project onto the chat computer.
    var cloneToken: String? { token }
    var login: String? { user?.username }

    var client: GitLabClient? {
        token.map { GitLabClient(host: host, token: $0, transport: transport) }
    }

    /// Picks up the token saved in the Keychain, if there is one.
    func restore() {
        guard let saved = Keychain.string(.gitlabToken), !saved.isEmpty else { return }
        token = saved
        host = Keychain.string(.gitlabHost).flatMap(GitLabClient.normalizedHost) ?? GitLabClient.defaultHost
    }

    /// Checks the token against the server, then keeps both. Nothing is saved if GitLab says no.
    func connect(host input: String, token input2: String) async -> Bool {
        let tokenText = input2.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let normalized = GitLabClient.normalizedHost(input) else {
            lastError = "Use the server's https address, such as gitlab.com or https://gitlab.example.com."
            return false
        }
        guard !tokenText.isEmpty else {
            lastError = "Paste a personal access token with the api scope."
            return false
        }
        isConnecting = true
        defer { isConnecting = false }
        lastError = nil
        let candidate = GitLabClient(host: normalized, token: tokenText, transport: transport)
        do {
            let found = try await candidate.currentUser()
            Keychain.setString(tokenText, for: .gitlabToken)
            Keychain.setString(normalized, for: .gitlabHost)
            token = tokenText
            host = normalized
            user = found
            branchCache = [:]
            await loadRepos()
            return true
        } catch {
            lastError = describe(error)
            return false
        }
    }

    func disconnect() {
        Keychain.remove(.gitlabToken)
        Keychain.remove(.gitlabHost)
        token = nil
        user = nil
        repos = []
        branchCache = [:]
        host = GitLabClient.defaultHost
    }

    /// Who the token belongs to and their projects. Called after restoring and after connecting.
    func refresh() async {
        guard let client else { return }
        if user == nil {
            do { user = try await client.currentUser() } catch {
                reposError = describe(error)
                return
            }
        }
        await loadRepos()
    }

    func loadRepos() async {
        guard !PreviewScenes.isActive, let client else { return }
        isLoadingRepos = true
        defer { isLoadingRepos = false }
        do {
            repos = try await client.projects()
            reposError = nil
        } catch {
            reposError = describe(error)
        }
    }

    func branches(of repo: RepoRef, refresh: Bool = false) async throws -> [GitHubBranch] {
        if !refresh, let cached = branchCache[repo.settingsKey], Date().timeIntervalSince(cached.date) < 120 {
            return cached.branches
        }
        guard let client else { throw GitHubAPIError(status: 401, message: "GitLab isn't connected") }
        let branches = try await client.branches(repo)
        branchCache[repo.settingsKey] = (Date(), branches)
        return branches
    }

    func repo(_ ref: RepoRef) -> GitHubRepo? {
        repos.first { $0.ref == ref }
    }

    func describe(_ error: Error, file: String = #fileID, function: String = #function) -> String {
        _ = ErrorExplainer.explain(error, file: file, function: function)
        if let error = error as? GitHubAPIError {
            if error.status == 401 { return "GitLab didn't accept the token. Make a new one with the api scope and connect again." }
            if error.status == 403 { return "GitLab says the token isn't allowed to do that. It needs the api scope. (\(error.message))" }
            if error.status == 429 { return "GitLab's request limit was reached. Try again in a minute." }
            return "GitLab said: \(error.message)"
        }
        if let error = error as? HTTPError, error.isOffline { return "You're offline." }
        return ErrorExplainer.explain(error).message
    }
}
