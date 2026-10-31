import AgentCore
import Foundation
import Observation

/// Manages OpenRouter sign-in plus any connected external AI gateways (OneProvider, SayGM, TeamoRouter, OmniRoute, Custom)
/// and combines all active model catalogs into one unified selector.
@MainActor
@Observable
final class OpenRouterAccount {
    private(set) var apiKey: String?
    private(set) var keyInfo: OpenRouterKeyInfo?
    private(set) var credits: OpenRouterCredits?
    private(set) var accountState = AccountState()
    /// External gateways configured by the user (API keys live exclusively in Keychain, never on disk).
    private(set) var externalProviders: [AIProviderEndpoint] = []
    private(set) var externalModelCounts: [String: Int] = [:]
    private(set) var externalBalances: [String: Double] = [:]
    private(set) var externalErrors: [String: String] = [:]

    private(set) var models: [ModelInfo] = []
    /// Full selectable catalog across OpenRouter + all connected gateways (chat, reasoning, vision, router, and image-generating models).
    private(set) var allSelectableModels: [ModelInfo] = []
    private(set) var modelsByID: [String: ModelInfo] = [:]
    private(set) var isLoadingModels = false
    private(set) var isSigningIn = false
    private(set) var lastError: String?
    private(set) var pinnedModelIDs: [String] = UserDefaults.standard.stringArray(forKey: "openRouterPinnedModels") ?? []
    private(set) var recentModelIDs: [String] = UserDefaults.standard.stringArray(forKey: "openRouterRecentModels") ?? []

    @ObservationIgnored weak var app: AppModel?
    let transport: any HTTPTransport
    private let cataloguePath: URL
    private let statePath: URL
    private let providersPath: URL
    private var openRouterCatalogCache: [ModelInfo] = []
    private var externalCatalogCache: [String: [ModelInfo]] = [:]
    private var catalogueLoadedAt: Date?

    init(transport: any HTTPTransport, paths: AppPaths) {
        self.transport = transport
        cataloguePath = paths.modelCatalogue
        statePath = paths.support.appendingPathComponent("openrouter-state.json")
        providersPath = paths.support.appendingPathComponent("ai-providers.json")
    }

    /// True when OpenRouter itself has a saved key.
    var hasOpenRouterKey: Bool { apiKey != nil }

    /// Ready external AI gateways with an enabled toggle and saved Keychain API key.
    var readyExternalProviders: [AIProviderEndpoint] { externalProviders.filter(\.isReady) }

    /// True when OpenRouter OR any external AI gateway (OneProvider, SayGM, TeamoRouter, OmniRoute, Custom) is ready.
    var isSignedIn: Bool { hasOpenRouterKey || !readyExternalProviders.isEmpty }

    /// Key passed to CloudRunner (`OPENROUTER_API_KEY` secret); uses a sentinel when only external providers are connected.
    var autonomousSecretKey: String? {
        if let apiKey, !apiKey.isEmpty { return apiKey }
        if !readyExternalProviders.isEmpty { return "__external_only__" }
        return nil
    }

    var client: OpenRouterClient {
        OpenRouterClient(
            transport: transport,
            apiKey: apiKey,
            extraProviders: readyExternalProviders,
            catalogueByID: modelsByID
        )
    }

    /// Free-AI requests left today, when OpenRouter reports it.
    var freeRequestsLeft: Int? { keyInfo?.freeRequestsLeftToday }
    var balance: Double? { credits?.balance ?? keyInfo?.limitRemaining }

    /// Live USD balances across OpenRouter and all connected external AI gateways that report wallet credit.
    var providerBalanceItems: [(id: String, name: String, balance: Double)] {
        var items: [(id: String, name: String, balance: Double)] = []
        if hasOpenRouterKey, let b = balance {
            items.append(("openrouter", "OpenRouter", b))
        }
        for endpoint in readyExternalProviders {
            if let b = externalBalances[endpoint.id] {
                items.append((endpoint.id, endpoint.name, b))
            }
        }
        return items
    }

    var activeProviderSummary: String {
        var names: [String] = []
        if hasOpenRouterKey { names.append("OpenRouter") }
        names.append(contentsOf: readyExternalProviders.map(\.name))
        return names.isEmpty ? "Not signed in" : names.joined(separator: ", ")
    }

    func contextLimit(for choice: ModelChoice, lastModelID: String? = nil) -> Int? {
        switch choice {
        case .model(let selected):
            return modelsByID[selected]?.contextLength
                ?? modelsByID[selected.replacingOccurrences(of: ":free", with: "")]?.contextLength
                ?? AIProviderGateway.inferredContextLength(for: AIProviderModelID.rawModelID(selected).lowercased())
        case .auto:
            if let lastModelID, let exact = modelsByID[lastModelID]?.contextLength { return exact }
            return modelsByID[ModelChoice.autoID]?.contextLength ?? 200_000
        case .free:
            if let lastModelID, let exact = modelsByID[lastModelID]?.contextLength { return exact }
            return modelsByID[ModelChoice.freeID]?.contextLength ?? 131_072
        }
    }

    private func providerKeychainAccount(_ id: String) -> String {
        "aiProvider.apiKey.\(id)"
    }

    func restore() {
        apiKey = Keychain.string(.openRouterKey)
        if let data = try? Data(contentsOf: statePath), let state = try? JSONCoding.decoder().decode(AccountState.self, from: data) {
            accountState = state
        }
        if let data = try? Data(contentsOf: providersPath),
           let saved = try? JSONCoding.decoder().decode([AIProviderEndpoint].self, from: data) {
            externalProviders = saved.map { item in
                var hydrated = item
                if let keyData = Keychain.data(account: providerKeychainAccount(item.id)) {
                    hydrated.apiKey = String(decoding: keyData, as: UTF8.self)
                }
                return hydrated
            }
        }
        if let data = try? Data(contentsOf: cataloguePath), let saved = try? JSONCoding.decoder().decode([ModelInfo].self, from: data) {
            openRouterCatalogCache = saved.filter { AIProviderModelID.decode($0.id) == nil }
            for item in saved {
                if let decoded = AIProviderModelID.decode(item.id) {
                    externalCatalogCache[decoded.providerID, default: []].append(item)
                }
            }
            for (pid, list) in externalCatalogCache {
                externalModelCounts[pid] = list.count
            }
            rebuildMergedModels()
        }
    }

    private func persistExternalProviders() {
        let stripped = externalProviders.map { item -> AIProviderEndpoint in
            var copy = item
            copy.apiKey = ""
            return copy
        }
        try? JSONCoding.encoder().encode(stripped).write(to: providersPath, options: .atomic)
    }

    // MARK: Managing External AI Gateways (OneProvider, SayGM, TeamoRouter, OmniRoute, Custom)

    func endpoint(for id: String) -> AIProviderEndpoint? {
        externalProviders.first { $0.id == id }
    }

    @discardableResult
    func saveExternalProvider(
        id: String,
        name: String,
        baseURL: String,
        apiKey rawKey: String,
        isEnabled: Bool = true
    ) async throws -> Int {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanKey = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedURL = AIProviderEndpoint.normalizeBaseURL(baseURL)
        guard !cleanName.isEmpty else {
            throw OpenRouterAPIError(httpStatus: 400, code: "missing_name", message: "Enter a name for this AI provider.")
        }
        guard !cleanKey.isEmpty else {
            throw OpenRouterAPIError(httpStatus: 400, code: "missing_key", message: "Paste your API key for \(cleanName).")
        }
        guard let url = URL(string: normalizedURL) else {
            throw OpenRouterAPIError(httpStatus: 400, code: "invalid_url", message: "Enter a valid base URL (for example https://api.oneprovider.dev/v1).")
        }
        try AIProviderGateway.validateEndpointURL(url)

        var candidate = AIProviderEndpoint(
            id: id,
            name: cleanName,
            baseURL: normalizedURL,
            apiKey: cleanKey,
            isEnabled: isEnabled
        )
        let fetched = try await AIProviderGateway.fetchModels(for: candidate, transport: transport)
        candidate.modelWireHints = fetched.wireHints

        Keychain.set(Data(cleanKey.utf8), account: providerKeychainAccount(id))
        if let idx = externalProviders.firstIndex(where: { $0.id == id }) {
            externalProviders[idx] = candidate
        } else {
            externalProviders.append(candidate)
        }
        externalCatalogCache[id] = fetched.models
        externalModelCounts[id] = fetched.models.count
        externalErrors[id] = nil
        if let usd = await AIProviderGateway.fetchBalance(for: candidate, transport: transport) {
            externalBalances[id] = usd
        }
        persistExternalProviders()
        rebuildMergedModels()
        persistMergedCatalog()
        Task {
            await app?.jobs.reconcileAutonomousConnectorSecrets()
            await app?.jobs.rotateAutonomousSecrets()
        }
        return fetched.models.count
    }

    func setExternalProviderEnabled(_ id: String, enabled: Bool) {
        guard let idx = externalProviders.firstIndex(where: { $0.id == id }) else { return }
        externalProviders[idx].isEnabled = enabled
        persistExternalProviders()
        rebuildMergedModels()
        Task {
            await app?.jobs.reconcileAutonomousConnectorSecrets()
            await app?.jobs.rotateAutonomousSecrets()
        }
    }

    func removeExternalProvider(_ id: String) {
        Keychain.remove(account: providerKeychainAccount(id))
        externalProviders.removeAll { $0.id == id }
        externalCatalogCache[id] = nil
        externalModelCounts[id] = nil
        externalBalances[id] = nil
        externalErrors[id] = nil
        persistExternalProviders()
        rebuildMergedModels()
        persistMergedCatalog()
        Task {
            await app?.jobs.reconcileAutonomousConnectorSecrets()
            if !isSignedIn {
                await app?.jobs.cleanupAllAutonomousSecrets()
            } else {
                await app?.jobs.rotateAutonomousSecrets()
            }
        }
    }

    // MARK: Signing in to OpenRouter (OAuth PKCE or API Key)

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
            if let returned = values["state"], returned != state {
                lastError = "OpenRouter's answer didn't match. Try again."
                return
            }
            let key = try await client.exchangeSignInCode(code, pkce: pkce)
            try await saveOpenRouterAPIKey(key)
        } catch WebSignIn.Failure.cancelled {
        } catch {
            lastError = describe(error)
        }
    }

    func saveOpenRouterAPIKey(_ rawKey: String) async throws {
        let clean = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else {
            throw OpenRouterAPIError(httpStatus: 400, code: "missing_key", message: "Paste your OpenRouter API key.")
        }
        let testClient = OpenRouterClient(transport: transport, apiKey: clean)
        let info = try await testClient.keyInfo()
        let previous = apiKey
        Keychain.setString(clean, for: .openRouterKey)
        apiKey = clean
        keyInfo = info
        credits = try? await testClient.credits()
        accountState = AccountState(isFreeTier: info.isFreeTier)
        saveState()
        if previous != clean {
            Task { await app?.jobs.rotateAutonomousSecrets() }
        }
        await loadModels(force: true)
    }

    /// Screenshots only: looks signed in, with nothing saved anywhere.
    func previewSignedIn() {
        apiKey = "preview"
        keyInfo = OpenRouterKeyInfo(label: "MAIPA-G", usage: 1.42, usageDaily: 0.08, isFreeTier: false, freeRequestsUsedToday: 3, freeRequestsLimitToday: 50, freeRequestsLeftToday: 47)
        credits = OpenRouterCredits(purchased: 5, used: 1.42)
        openRouterCatalogCache = [
            ModelInfo(id: "openrouter/auto", name: "OpenRouter: Auto", outputModalities: ["text"], supportedParameters: ["tools", "reasoning"]),
            ModelInfo(id: "anthropic/claude-sonnet-5.5", name: "Anthropic: Claude Sonnet 5.5", contextLength: 200_000, outputModalities: ["text"], supportedParameters: ["tools", "reasoning"]),
            ModelInfo(id: "google/gemini-image", name: "Google: Gemini Image", promptPrice: 0.000001, completionPrice: 0.000004, inputModalities: ["text", "image"], outputModalities: ["text", "image"], supportedParameters: ["tools"]),
            ModelInfo(id: "qwen/qwen-vl:free", name: "Qwen: Vision Free", promptPrice: 0, completionPrice: 0, inputModalities: ["text", "image"], outputModalities: ["text"], supportedParameters: ["tools"]),
        ]
        rebuildMergedModels()
    }

    func signOut() {
        Keychain.remove(.openRouterKey)
        apiKey = nil
        keyInfo = nil
        credits = nil
        accountState = AccountState()
        saveState()
        rebuildMergedModels()
        Task {
            if !isSignedIn {
                await app?.jobs.cleanupAllAutonomousSecrets()
            } else {
                await app?.jobs.rotateAutonomousSecrets()
            }
        }
    }

    // MARK: Money

    func refreshKeyInfo() async {
        guard !PreviewScenes.isActive else { return }
        if hasOpenRouterKey {
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
        // Also refresh live USD balances for all connected external gateways (OneProvider, TeamoRouter, OmniRoute, SayGM, Custom).
        for endpoint in readyExternalProviders {
            if let usd = await AIProviderGateway.fetchBalance(for: endpoint, transport: transport) {
                externalBalances[endpoint.id] = usd
            }
        }
    }

    /// Models OpenRouter refused in the current session as app-restricted (kept session-local so a
    /// temporary provider hiccup never hides a model forever from search).
    private(set) var restrictedModelIDs: Set<String> = []

    func markRestricted(_ modelID: String) {
        guard !modelID.isEmpty, modelID != "openrouter/auto", !restrictedModelIDs.contains(modelID) else { return }
        restrictedModelIDs.insert(modelID)
    }

    func togglePin(_ modelID: String) {
        if let idx = pinnedModelIDs.firstIndex(of: modelID) {
            pinnedModelIDs.remove(at: idx)
        } else {
            pinnedModelIDs.insert(modelID, at: 0)
        }
        UserDefaults.standard.set(pinnedModelIDs, forKey: "openRouterPinnedModels")
    }

    func isPinned(_ modelID: String) -> Bool {
        pinnedModelIDs.contains(modelID)
    }

    func recordRecent(_ choice: ModelChoice) {
        guard case .model(let id) = choice, !id.isEmpty else { return }
        recentModelIDs.removeAll { $0 == id }
        recentModelIDs.insert(id, at: 0)
        if recentModelIDs.count > 8 {
            recentModelIDs = Array(recentModelIDs.prefix(8))
        }
        UserDefaults.standard.set(recentModelIDs, forKey: "openRouterRecentModels")
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

    /// Loads OpenRouter's catalogue AND all connected external AI gateways, at most every hour unless `force`.
    func loadModels(force: Bool = false) async {
        if !force, let loaded = catalogueLoadedAt, Date().timeIntervalSince(loaded) < 3600, !allSelectableModels.isEmpty { return }
        isLoadingModels = true
        defer { isLoadingModels = false }

        // 1. OpenRouter public/authenticated catalog
        if let fresh = try? await client.models() {
            openRouterCatalogCache = fresh
        }

        // 2. Every enabled external AI gateway (OneProvider, SayGM, TeamoRouter, OmniRoute, Custom)
        var updatedWireHints = false
        for idx in externalProviders.indices where externalProviders[idx].isReady {
            let endpoint = externalProviders[idx]
            do {
                let fetched = try await AIProviderGateway.fetchModels(for: endpoint, transport: transport)
                externalCatalogCache[endpoint.id] = fetched.models
                externalModelCounts[endpoint.id] = fetched.models.count
                externalErrors[endpoint.id] = nil
                if externalProviders[idx].modelWireHints != fetched.wireHints {
                    externalProviders[idx].modelWireHints = fetched.wireHints
                    updatedWireHints = true
                }
            } catch {
                externalErrors[endpoint.id] = ErrorExplainer.explain(error).message
            }
        }
        if updatedWireHints {
            persistExternalProviders()
        }

        rebuildMergedModels()
        if !allSelectableModels.isEmpty {
            catalogueLoadedAt = Date()
            persistMergedCatalog()
        }
    }

    private func rebuildMergedModels() {
        var combined: [ModelInfo] = []
        // Put connected external providers first when OpenRouter isn't signed in; otherwise merge cleanly.
        let externalActive = readyExternalProviders.flatMap { externalCatalogCache[$0.id] ?? [] }
        if hasOpenRouterKey {
            combined = externalActive + openRouterCatalogCache
        } else if !readyExternalProviders.isEmpty {
            // Keep external models prominent, plus OpenRouter catalog only for reference if user signs in later,
            // wait — ONLY show models from connected providers when external providers are active without OpenRouter,
            // so tapping a model never hits an unsigned-in OpenRouter 401!
            combined = externalActive
        } else {
            combined = openRouterCatalogCache
        }
        modelsByID = Dictionary(combined.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        models = combined.filter { $0.isChatModel && !restrictedModelIDs.contains($0.id) }
        allSelectableModels = combined.filter(\.isSelectableModel)
    }

    private func persistMergedCatalog() {
        let allCached = readyExternalProviders.flatMap { externalCatalogCache[$0.id] ?? [] } + openRouterCatalogCache
        try? JSONCoding.encoder().encode(allCached).write(to: cataloguePath, options: .atomic)
    }

    /// The name to show for a chat's AI choice.
    func label(for choice: ModelChoice) -> String {
        switch choice {
        case .auto: return "Auto"
        case .free: return "Free AIs"
        case .model(let id):
            return displayName(forModelID: id)
        }
    }

    func displayName(forModelID id: String) -> String {
        if let info = modelsByID[id] { return info.shortName }
        if let decoded = AIProviderModelID.decode(id) {
            if let match = allSelectableModels.first(where: { $0.id == id || AIProviderModelID.rawModelID($0.id) == decoded.rawModelID }) {
                return match.shortName
            }
            return AIProviderGateway.prettifyModelSlug(decoded.rawModelID)
        }
        if let match = allSelectableModels.first(where: { AIProviderModelID.rawModelID($0.id) == id }) {
            return match.shortName
        }
        return AIProviderGateway.prettifyModelSlug(id)
    }

    /// The thinking levels to offer for a choice. Empty means the AI doesn't think in levels.
    func thinkingLevels(for choice: ModelChoice) -> [ThinkingLevel] {
        switch choice {
        case .auto:
            if !hasOpenRouterKey, let firstExt = readyExternalProviders.first,
               let extModels = externalCatalogCache[firstExt.id],
               extModels.contains(where: { !$0.thinkingLevels.isEmpty }) {
                return [.low, .medium, .high, .xhigh, .max]
            }
            return modelsByID[ModelChoice.autoID]?.thinkingLevels ?? [.low, .medium, .high]
        case .free:
            return modelsByID[ModelChoice.freeID]?.thinkingLevels ?? [.low, .medium, .high]
        case .model(let id):
            return modelsByID[id]?.thinkingLevels ?? []
        }
    }

    /// Whether the choice can use tools (and so read repos and ask questions).
    func supportsTools(_ choice: ModelChoice) -> Bool {
        switch choice {
        case .auto, .free: return true
        case .model(let id): return modelsByID[id]?.supportsTools ?? true
        }
    }

    func describe(_ error: Error, file: String = #fileID, function: String = #function) -> String {
        if let error = error as? OpenRouterAPIError {
            _ = ErrorExplainer.explain(error, file: file, function: function)
            switch error.kind {
            case .invalidKey: return "That API key wasn't accepted. Double-check it and try again."
            default: return error.message
            }
        }
        if let error = error as? HTTPError, error.isOffline { return "You're offline." }
        return ErrorExplainer.explain(error, file: file, function: function).message
    }
}
