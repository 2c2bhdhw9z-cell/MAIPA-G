import AgentCore
import Foundation
import Observation

/// The user's GitHub connection: their own MAIPA-G app on GitHub, where it is installed, and the
/// repos it can reach.
@MainActor
@Observable
final class GitHubAccount {
    enum Phase: Equatable {
        case notConnected
        /// The app was made, but isn't let into any repos yet (step 2 of connecting).
        case needsInstall
        case connected
    }

    private(set) var phase: Phase = .notConnected
    private(set) var credentials: GitHubAppCredentials?
    private(set) var installationID: Int?
    private(set) var user: GitHubUser?
    private(set) var repos: [GitHubRepo] = []
    private(set) var isLoadingRepos = false
    private(set) var reposError: String?
    /// What the connect sheet shows while it works, such as "Setting up…".
    private(set) var progress: String?
    private(set) var lastError: String?
    /// After a cancelled attempt the next one uses a slightly different app name, in case the
    /// first was taken.
    private var attempts = 0

    let transport: any HTTPTransport
    private(set) var session: GitHubAppSession?
    private var branchCache: [String: (date: Date, branches: [GitHubBranch])] = [:]

    init(transport: any HTTPTransport) {
        self.transport = transport
    }

    var isConnected: Bool { phase == .connected }
    var login: String? { user?.login ?? credentials?.ownerLogin }

    /// A client that acts as MAIPA-G's own app (the bot).
    var client: GitHubClient? {
        session.map { GitHubClient(transport: transport, tokens: $0) }
    }

    /// The public API, for things that need no sign-in.
    var publicClient: GitHubClient { GitHubClient(transport: transport, tokens: nil) }

    // MARK: Starting up

    /// Picks up the connection saved in the Keychain, if there is one.
    func restore() {
        guard let credentials = Keychain.value(GitHubAppCredentials.self, for: .githubApp) else {
            phase = .notConnected
            return
        }
        self.credentials = credentials
        guard let installation = Keychain.string(.githubInstallation).flatMap(Int.init) else {
            phase = .needsInstall
            return
        }
        installationID = installation
        do {
            try startSession()
            phase = .connected
        } catch {
            lastError = "The saved GitHub key couldn't be read. Connect GitHub again."
            phase = .notConnected
        }
    }

    private func startSession() throws {
        guard let credentials, let installationID else { return }
        let signer = try SecurityRS256Signer(pem: credentials.privateKeyPEM)
        let token = Keychain.value(GitHubUserToken.self, for: .githubUserToken)
        session = GitHubAppSession(
            credentials: credentials,
            installationID: installationID,
            userToken: token,
            signer: signer,
            transport: transport,
            onUserTokenChange: { token in
                await MainActor.run { Keychain.setValue(token, for: .githubUserToken) }
            }
        )
    }

    /// Fills in who the user is and their repos, and notices if the app was deleted or uninstalled
    /// on GitHub's website. Called after restoring and after connecting.
    func refresh() async {
        guard let credentials, let signer = try? SecurityRS256Signer(pem: credentials.privateKeyPEM) else { return }
        guard await GitHubConnect.appStillWorks(credentials: credentials, signer: signer, transport: transport) else {
            forget()
            lastError = "Your MAIPA-G app is no longer on GitHub. Connect GitHub again to make a new one."
            return
        }
        guard isConnected, let client else { return }
        do {
            repos = try await client.installationRepositories()
            reposError = nil
        } catch let error as GitHubAPIError where error.status == 401 || error.status == 404 {
            // The app exists but may have been uninstalled from the account.
            if let installations = try? await GitHubConnect.installations(credentials: credentials, signer: signer, transport: transport), installations.isEmpty {
                Keychain.remove(.githubInstallation)
                installationID = nil
                session = nil
                repos = []
                phase = .needsInstall
                lastError = "MAIPA-G was taken off your GitHub account. Tap Let MAIPA-G in to add it back."
                return
            }
            reposError = describe(error)
        } catch {
            reposError = describe(error)
        }
        if user == nil {
            user = try? await client.authenticatedUser()
        }
    }

    /// True when the six-month GitHub sign-in has run out. MAIPA-G still reads and saves without
    /// it; it's only needed to make new repos.
    var needsSignInAgain: Bool {
        guard isConnected, !PreviewScenes.isActive else { return false }
        guard let token = Keychain.value(GitHubUserToken.self, for: .githubUserToken) else { return true }
        return !token.isFresh() && !token.canRefresh()
    }

    private func forget() {
        for item in [Keychain.Item.githubApp, .githubInstallation, .githubUserToken] { Keychain.remove(item) }
        credentials = nil
        installationID = nil
        user = nil
        repos = []
        session = nil
        branchCache = [:]
        phase = .notConnected
    }

    // MARK: Connecting

    /// Step 1: make the user's own MAIPA-G app on GitHub. Step 2 follows straight after.
    func connect() async {
        lastError = nil
        let state = Hashing.randomToken()
        let suffix = String((0..<4).compactMap { _ in "abcdefghjkmnpqrstuvwxyz23456789".randomElement() })
        let name = attempts == 0 ? "MAIPA-G" : "MAIPA-G-" + suffix
        attempts += 1
        progress = "Waiting for GitHub…"
        defer { progress = nil }
        do {
            let callback = try await WebSignIn.shared.open(GitHubConnect.manifestPageURL(state: state, appName: name))
            let values = WebSignIn.values(in: callback)
            guard values["state"] == state, let code = values["code"] else {
                lastError = "GitHub's answer didn't match. Try again."
                return
            }
            progress = "Setting up your MAIPA-G app…"
            let credentials = try await GitHubConnect.convertManifest(code: code, transport: transport)
            Keychain.setValue(credentials, for: .githubApp)
            Keychain.remove(.githubInstallation)
            Keychain.remove(.githubUserToken)
            self.credentials = credentials
            phase = .needsInstall
            attempts = 0
            await install()
        } catch WebSignIn.Failure.cancelled {
            // Nothing to do; the sheet explains what to try.
        } catch {
            lastError = describe(error)
        }
    }

    /// Step 2: install the app on the user's account and let it act for them.
    func install() async {
        guard let credentials else { return }
        lastError = nil
        progress = "Waiting for GitHub…"
        defer { progress = nil }
        do {
            // The app asks for sign-in during installation, so GitHub goes from installing straight
            // to "Authorize", then back to MAIPA-G with a code.
            let callback = try await WebSignIn.shared.open(GitHubConnect.installURL(slug: credentials.slug))
            let values = WebSignIn.values(in: callback)
            progress = "Finishing up…"
            try await finishConnecting(code: values["code"], verifier: nil)
        } catch WebSignIn.Failure.cancelled {
            // The app is made but not installed; the sheet offers step 2 again.
            await checkInstallation()
        } catch {
            lastError = describe(error)
        }
    }

    /// Signs in again as the user, for when their six-month sign-in has run out.
    func reauthorize() async {
        guard let credentials else { return }
        let state = Hashing.randomToken()
        let pkce = PKCE()
        progress = "Waiting for GitHub…"
        defer { progress = nil }
        do {
            let callback = try await WebSignIn.shared.open(GitHubConnect.authorizeURL(clientID: credentials.clientID, state: state, pkce: pkce))
            let values = WebSignIn.values(in: callback)
            guard values["state"] == state else {
                lastError = "GitHub's answer didn't match. Try again."
                return
            }
            try await finishConnecting(code: values["code"], verifier: pkce.verifier)
        } catch WebSignIn.Failure.cancelled {
        } catch {
            lastError = describe(error)
        }
    }

    private func finishConnecting(code: String?, verifier: String?) async throws {
        guard let credentials else { return }
        if let code {
            let token = try await GitHubConnect.exchangeAuthorizationCode(code, credentials: credentials, verifier: verifier, transport: transport)
            Keychain.setValue(token, for: .githubUserToken)
        }
        // Where the app really is installed, asked as the app itself rather than trusting the
        // address GitHub sent back.
        let signer = try SecurityRS256Signer(pem: credentials.privateKeyPEM)
        let installations = try await GitHubConnect.installations(credentials: credentials, signer: signer, transport: transport)
        guard let installation = installations.first(where: { $0.accountLogin.caseInsensitiveCompare(credentials.ownerLogin) == .orderedSame }) ?? installations.first else {
            phase = .needsInstall
            lastError = "MAIPA-G isn't installed on your account yet. Tap Let MAIPA-G in, and choose All repositories."
            return
        }
        Keychain.setString(String(installation.id), for: .githubInstallation)
        installationID = installation.id
        try startSession()
        phase = .connected
        user = nil
        await refresh()
    }

    /// After the install sheet was closed: maybe the user did install, and just didn't come back.
    private func checkInstallation() async {
        guard let credentials, let signer = try? SecurityRS256Signer(pem: credentials.privateKeyPEM) else { return }
        if let installations = try? await GitHubConnect.installations(credentials: credentials, signer: signer, transport: transport), !installations.isEmpty {
            try? await finishConnecting(code: nil, verifier: nil)
        }
    }

    /// Forgets the connection on this phone and takes MAIPA-G off the account. The app itself stays
    /// on GitHub (Settings links to it), so connecting again later is quick.
    func disconnect() async {
        if let credentials, let installationID, let signer = try? SecurityRS256Signer(pem: credentials.privateKeyPEM) {
            try? await GitHubConnect.uninstall(installationID: installationID, credentials: credentials, signer: signer, transport: transport)
        }
        forget()
    }

    /// Screenshots only: looks connected, with made-up repos and nothing saved anywhere.
    func previewConnected() {
        credentials = GitHubAppCredentials(appID: 1, slug: "maipa-g", name: "MAIPA-G", clientID: "preview", clientSecret: "", privateKeyPEM: "", ownerLogin: "2c2bhdhw9z-cell", htmlURL: "https://github.com/apps/maipa-g")
        installationID = 1
        phase = .connected
        let names = ["MAIPA-G", "Continuum-", "snes-tas-studio", "CultivationMMO", "nightreap-survivors"]
        repos = names.enumerated().map { index, name in
            GitHubRepo(id: index, name: name, fullName: "2c2bhdhw9z-cell/\(name)", ownerLogin: "2c2bhdhw9z-cell", isPrivate: index == 3,
                       defaultBranch: name == "Continuum-" ? "master" : "main", pushedAt: Date().addingTimeInterval(Double(-index) * 40_000),
                       language: ["Swift", "Rust", "Swift", "Rust", "TypeScript"][index], htmlURL: "https://github.com/2c2bhdhw9z-cell/\(name)")
        }
    }

    // MARK: Repos

    func loadRepos() async {
        guard !PreviewScenes.isActive else { return }
        guard let client else { return }
        isLoadingRepos = true
        defer { isLoadingRepos = false }
        do {
            repos = try await client.installationRepositories()
            reposError = nil
        } catch {
            reposError = describe(error)
        }
    }

    func branches(of repo: RepoRef, refresh: Bool = false) async throws -> [GitHubBranch] {
        if !refresh, let cached = branchCache[repo.fullName], Date().timeIntervalSince(cached.date) < 120 {
            return cached.branches
        }
        guard let client else { throw GitHubAPIError(status: 401, message: "GitHub isn't connected") }
        let branches = try await client.branches(repo)
        branchCache[repo.fullName] = (Date(), branches)
        return branches
    }

    func repo(named fullName: String) -> GitHubRepo? {
        repos.first { $0.fullName.caseInsensitiveCompare(fullName) == .orderedSame }
    }

    /// A token that can only read `repo`'s files and lasts about an hour, for cloning a private repo
    /// onto a chat's computer. Public repos don't need one. It is made fresh each time and isn't
    /// kept here; the chat that asked keeps it until it is nearly used up.
    func readOnlyToken(for repo: RepoRef) async throws -> (token: String, expiresAt: Date) {
        guard let session else { throw GitHubAPIError(status: 401, message: "GitHub isn't connected") }
        return try await session.readOnlyToken(forRepository: repo.name)
    }

    /// GitHub's page where the user picks which repos MAIPA-G may use.
    var installationSettingsURL: URL? {
        installationID.map { URL(string: "https://github.com/settings/installations/\($0)")! }
    }

    func describe(_ error: Error) -> String {
        if let error = error as? GitHubAPIError {
            if error.isRateLimited { return "GitHub's hourly limit was reached. It resets within the hour." }
            if error.isUnauthorized { return "GitHub didn't accept MAIPA-G's key. Connect GitHub again in Settings." }
            return "GitHub said: \(error.message)"
        }
        if let error = error as? HTTPError, error.isOffline { return "You're offline." }
        if let error = error as? GitHubConnect.Failure {
            switch error {
            case .oauth(_, let message): return "GitHub said: \(message)"
            case .unexpectedReply(let message): return message
            case .notInstalled: return "MAIPA-G isn't installed on your account yet."
            }
        }
        if case GitHubAppSession.Failure.userSignInExpired = error { return "Your GitHub sign-in ran out. Sign in again in Settings." }
        return "Something went wrong talking to GitHub."
    }
}
