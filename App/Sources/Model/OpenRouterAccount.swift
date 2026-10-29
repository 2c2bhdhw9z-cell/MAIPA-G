import AgentCore
import Foundation
import Observation

/// The user's OpenRouter sign-in, what it can spend, and OpenRouter's list of AIs.
@MainActor
@Observable
final class OpenRouterAccount {
    private(set) var apiKey: String?
    private(set) var keyInfo: OpenRouterKeyInfo?
    private(set) var credits: OpenRouterCredits?
    private(set) var accountState = AccountState()
    private(set) var models: [ModelInfo] = []
    private(set) var modelsByID: [String: ModelInfo] = [:]
    private(set) var isSigningIn = false
    private(set) var lastError: String?

    let transport: any HTTPTransport
    private let cataloguePath: URL
    private let statePath: URL
    private var catalogueLoadedAt: Date?

    init(transport: any HTTPTransport, paths: AppPaths) {
        self.transport = transport
        cataloguePath = paths.modelCatalogue
        statePath = paths.support.appendingPathComponent("openrouter-state.json")
    }

    var isSignedIn: Bool { apiKey != nil }

    var client: OpenRouterClient { OpenRouterClient(transport: transport, apiKey: apiKey) }

    /// Free-AI requests left today, when OpenRouter reports it.
    var freeRequestsLeft: Int? { keyInfo?.freeRequestsLeftToday }
    var balance: Double? { credits?.balance ?? keyInfo?.limitRemaining }

    func restore() {
        apiKey = Keychain.string(.openRouterKey)
        if let data = try? Data(contentsOf: statePath), let state = try? JSONCoding.decoder().decode(AccountState.self, from: data) {
            accountState = state
        }
        if let data = try? Data(contentsOf: cataloguePath), let saved = try? JSONCoding.decoder().decode([ModelInfo].self, from: data) {
            setModels(saved)
        }
    }

    // MARK: Signing in

    func signIn() async {
        lastError = nil
        isSigningIn = true
        defer { isSigningIn = false }
        let pkce = PKCE()
        let state = Hashing.randomToken()
        let callback = GitHubConnect.page("openrouter/")
        do {
            let answer = try await WebSignIn.shared.open(OpenRouterClient.signInURL(callback: callback, pkce: pkce, state: state))
            let values = WebSignIn.values(in: answer)
            guard let code = values["code"] else {
                lastError = "OpenRouter didn't send a sign-in code. Try again."
                return
            }
            // OpenRouter returns the state unchanged; a missing one is allowed, a wrong one isn't.
            if let returned = values["state"], returned != state {
                lastError = "OpenRouter's answer didn't match. Try again."
                return
            }
            let key = try await client.exchangeSignInCode(code, pkce: pkce)
            Keychain.setString(key, for: .openRouterKey)
            apiKey = key
            accountState = AccountState()
            saveState()
            await refreshKeyInfo()
        } catch WebSignIn.Failure.cancelled {
        } catch {
            lastError = describe(error)
        }
    }

    /// Screenshots only: looks signed in, with nothing saved anywhere.
    func previewSignedIn() {
        apiKey = "preview"
        keyInfo = OpenRouterKeyInfo(label: "MAIPA-G", usage: 1.42, usageDaily: 0.08, isFreeTier: false, freeRequestsUsedToday: 3, freeRequestsLimitToday: 50, freeRequestsLeftToday: 47)
        credits = OpenRouterCredits(purchased: 5, used: 1.42)
    }

    func signOut() {
        Keychain.remove(.openRouterKey)
        apiKey = nil
        keyInfo = nil
        credits = nil
        accountState = AccountState()
        saveState()
    }

    // MARK: Money

    func refreshKeyInfo() async {
        guard isSignedIn, !PreviewScenes.isActive else { return }
        do {
            let info = try await client.keyInfo()
            keyInfo = info
            credits = try? await client.credits()
            if accountState.isFreeTier != info.isFreeTier {
                accountState.isFreeTier = info.isFreeTier
                saveState()
            }
        } catch let error as OpenRouterAPIError where error.kind == .invalidKey {
            lastError = "OpenRouter no longer accepts MAIPA-G's sign-in. Sign in again."
            signOut()
        } catch {
            // Offline or busy: keep what we knew.
        }
    }

    /// Remembers that a paid request was refused for lack of credit.
    func markOutOfCredits() {
        accountState.outOfCreditsAt = Date()
        saveState()
    }

    private func saveState() {
        try? JSONCoding.encoder().encode(accountState).write(to: statePath, options: .atomic)
    }

    // MARK: The list of AIs

    /// Loads OpenRouter's catalogue, at most every six hours unless `force`.
    func loadModels(force: Bool = false) async {
        if !force, let loaded = catalogueLoadedAt, Date().timeIntervalSince(loaded) < 6 * 3600, !models.isEmpty { return }
        do {
            let fresh = try await client.models()
            setModels(fresh)
            catalogueLoadedAt = Date()
            try? JSONCoding.encoder().encode(fresh).write(to: cataloguePath, options: .atomic)
        } catch {
            // Keep the saved list.
        }
    }

    private func setModels(_ list: [ModelInfo]) {
        models = list.filter(\.isChatModel)
        modelsByID = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// The name to show for a chat's AI choice.
    func label(for choice: ModelChoice) -> String {
        switch choice {
        case .auto: return "Auto"
        case .free: return "Free AIs"
        case .model(let id): return modelsByID[id]?.shortName ?? id.split(separator: "/").last.map(String.init) ?? id
        }
    }

    /// The thinking levels to offer for a choice. Empty means the AI doesn't think in levels.
    func thinkingLevels(for choice: ModelChoice) -> [ThinkingLevel] {
        switch choice {
        case .auto: return modelsByID[ModelChoice.autoID]?.thinkingLevels ?? [.low, .medium, .high]
        case .free: return modelsByID[ModelChoice.freeID]?.thinkingLevels ?? [.low, .medium, .high]
        case .model(let id): return modelsByID[id]?.thinkingLevels ?? []
        }
    }

    /// Whether the choice can use tools (and so read repos and ask questions).
    func supportsTools(_ choice: ModelChoice) -> Bool {
        switch choice {
        case .auto, .free: return true
        case .model(let id): return modelsByID[id]?.supportsTools ?? true
        }
    }

    func describe(_ error: Error) -> String {
        if let error = error as? OpenRouterAPIError {
            switch error.kind {
            case .invalidKey: return "OpenRouter didn't accept that sign-in. Try again."
            default: return "OpenRouter said: \(error.message)"
            }
        }
        if let error = error as? HTTPError, error.isOffline { return "You're offline." }
        return "Something went wrong signing in to OpenRouter."
    }
}
