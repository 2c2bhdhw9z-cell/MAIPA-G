import AgentCore
import Foundation
import Observation

@MainActor
@Observable
final class ConnectorLibrary {
    private(set) var catalog: [RegistryServer] = []
    private(set) var connected: [ConnectorConfiguration] = []
    private(set) var toolDefinitions: [UUID: [ConnectorToolDefinition]] = [:]
    private(set) var states: [UUID: ConnectorConnectionState] = [:]
    private(set) var errors: [UUID: String] = [:]
    private(set) var isLoading = false
    private(set) var nextCursor: String?
    var query = ""

    @ObservationIgnored weak var app: AppModel?
    @ObservationIgnored private let transport: any HTTPTransport
    @ObservationIgnored private let cacheURL: URL
    @ObservationIgnored private let store: ProductStore<ConnectorRecord>
    @ObservationIgnored private var sessions: [UUID: MCPConnectorSession] = [:]
    @ObservationIgnored private var setupKeepAwakeTask: Task<Void, Never>?

    init(transport: any HTTPTransport, paths: AppPaths) {
        self.transport = transport; cacheURL = paths.connectorCatalogue
        store = ProductStore(dataDirectory: paths.data, folder: "connectors")
    }

    func load() async {
        if let data = try? Data(contentsOf: cacheURL), let saved = try? JSONCoding.decoder().decode([RegistryServer].self, from: data) {
            catalog = saved.sorted(by: MCPRegistryClient.catalogOrder)
        }
        var loaded = await store.loadAll().compactMap(Self.configuration)
        for index in loaded.indices {
            let item = loaded[index]
            if item.serverID == "mcp:github" || item.endpoint?.host?.lowercased() == "api.githubcopilot.com" {
                var migrated = ConnectorConfiguration(
                    id: item.id,
                    serverID: "builtin:github",
                    displayName: "GitHub",
                    kind: .builtin,
                    endpoint: URL(string: "https://api.github.com"),
                    launchValues: ["provider": "github", "base_url": "https://api.github.com", "auth_style": "bearer"],
                    secretNames: ["api_key"]
                )
                migrated.disabledTools = item.disabledTools
                loaded[index] = migrated
                if let data = try? JSONCoding.encoder().encode(migrated), let json = JSONValue.parse(data) {
                    let record = ConnectorRecord(id: migrated.id, serverID: migrated.serverID, displayName: migrated.displayName, configuration: json)
                    try? await store.save(record)
                }
            }
        }
        connected = loaded.sorted { $0.displayName < $1.displayName }
        for configuration in connected { await restore(configuration) }
        if !PreviewScenes.isActive, app?.settings.chatComputerOff == false,
           let control = computerControl(),
           !UserDefaults.standard.bool(forKey: Self.toolsReadyDefaultsKey(control.machine)) {
            keepComputerAwakeDuringSetup()
        }
    }

    func search(reset: Bool = true) async {
        guard !isLoading else { return }
        isLoading = true; defer { isLoading = false }
        do {
            let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
            if reset {
                let found = try await firstPages(for: text)
                catalog = Self.ranked(Self.unique(found.servers), for: text)
                nextCursor = found.nextCursor
            } else {
                let page = try await MCPRegistryClient(transport: transport).page(search: query, cursor: nextCursor)
                catalog = Self.ranked(Self.unique(catalog + page.servers), for: text)
                nextCursor = page.nextCursor
            }
            try? JSONCoding.encoder().encode(catalog).write(to: cacheURL, options: .atomic)
        } catch { if catalog.isEmpty { errors[UUID()] = ErrorExplainer.explain(error).message } }
    }

    func lookup(_ search: String) async throws -> [RegistryServer] {
        let text = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let pages = try await firstPages(for: text)
        let found = Self.ranked(Self.unique(pages.servers), for: text)
        catalog = Self.ranked(Self.unique(catalog + found), for: query.trimmingCharacters(in: .whitespacesAndNewlines))
        try? JSONCoding.encoder().encode(catalog).write(to: cacheURL, options: .atomic)
        return found
    }

    private func firstPages(for text: String) async throws -> (servers: [RegistryServer], nextCursor: String?) {
        let client = MCPRegistryClient(transport: transport)
        let spellings = Self.spellings(of: text)
        async let extra = ConnectorLibrary.bestEffortPages(Array(spellings.dropFirst()), client: client)
        let typed = try await client.page(search: spellings[0], limit: 100)
        let others = await extra
        return (typed.servers + others, typed.nextCursor)
    }

    nonisolated static func spellings(of text: String) -> [String] {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        var spellings = [text]
        for candidate in [words.joined(), words.joined(separator: "-")] where !candidate.isEmpty && !spellings.contains(candidate) {
            spellings.append(candidate)
        }
        return spellings
    }

    nonisolated private static func bestEffortPages(_ spellings: [String], client: MCPRegistryClient) async -> [RegistryServer] {
        await withTaskGroup(of: [RegistryServer].self, returning: [RegistryServer].self) { group in
            for spelling in spellings {
                group.addTask { (try? await client.page(search: spelling, limit: 100))?.servers ?? [] }
            }
            var servers: [RegistryServer] = []
            for await page in group { servers += page }
            return servers
        }
    }

    nonisolated private static func unique(_ servers: [RegistryServer]) -> [RegistryServer] {
        Array(servers.reduce(into: [String: RegistryServer]()) { $0[$1.name] = $1 }.values)
    }

    nonisolated static func ranked(_ servers: [RegistryServer], for query: String) -> [RegistryServer] {
        let title = compacted(query)
        let publisherQuery = query.filter { !$0.isWhitespace }.lowercased()
        func rank(_ server: RegistryServer) -> Int {
            let publisher = server.name.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).first.map { $0.lowercased() } ?? ""
            let ownPublisher = !publisherQuery.isEmpty && publisher.contains(publisherQuery)
            if !title.isEmpty, compacted(server.displayName) == title { return ownPublisher ? 0 : 1 }
            return ownPublisher ? 2 : 3
        }
        return servers.map { (rank: rank($0), server: $0) }
            .sorted { $0.rank != $1.rank ? $0.rank < $1.rank : MCPRegistryClient.catalogOrder($0.server, $1.server) }
            .map(\.server)
    }

    nonisolated private static func compacted(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    // MARK: - Adding & Connecting Any of the 100+ Providers or Registry Servers

    func connectCatalogProvider(_ spec: IntegrationProviderSpec) async -> ConnectorConfiguration? {
        if let existing = connected.first(where: { spec.matches($0.displayName + " " + $0.serverID) }) {
            return existing
        }
        switch spec.mode {
        case .publicZeroKey(let providerKey):
            let config = ConnectorConfiguration(
                serverID: "builtin:\(spec.id)",
                displayName: spec.name,
                kind: .builtin,
                launchValues: ["provider": providerKey]
            )
            await save(config)
            await restore(config)
            return config

        case .appleNative(let appleKey, _):
            let granted = (try? await AppleDeviceIntegrations.requestAuthorization(for: appleKey)) ?? false
            let config = ConnectorConfiguration(
                serverID: "apple:\(spec.id)",
                displayName: spec.name,
                kind: .apple,
                launchValues: ["apple_key": appleKey]
            )
            await save(config)
            if granted {
                await restore(config)
            } else {
                toolDefinitions[config.id] = AppleDeviceIntegrations.definitions(for: config)
                states[config.id] = .authorizationNeeded
                errors[config.id] = "Turn on \(spec.name) permission for MAIPA-G in iOS Settings."
            }
            return config

        case .remoteMCP(let urlText, _, let authHeader, _):
            guard let url = URL(string: urlText) else { return nil }
            let config = ConnectorConfiguration(
                serverID: "mcp:\(spec.id)",
                displayName: spec.name,
                endpoint: url,
                authHeaderName: authHeader
            )
            // Convenience: if connecting GitHub MCP and the user already signed in to GitHub in MAIPA-G, seed credential if none set.
            if spec.id == "github", let ghToken = Keychain.string(.githubUserToken), !ghToken.isEmpty {
                Keychain.setValue(ConnectorCredential(accessToken: ghToken, clientID: "github-app"), account: credentialKey(config.id))
            }
            await save(config)
            await restore(config)
            return config

        case .apiKeyREST(let providerKey, let baseURL, let authStyle, let authName, _, let extraKey, _, _):
            var values: [String: String] = [
                "provider": providerKey,
                "auth_style": authStyle.rawValue,
                "auth_name": authName,
            ]
            if let extraKey { values["extra_key"] = extraKey }
            let config = ConnectorConfiguration(
                serverID: "builtin:\(spec.id)",
                displayName: spec.name,
                kind: .builtin,
                endpoint: URL(string: baseURL),
                launchValues: values,
                secretNames: ["api_key"],
                authHeaderName: authName
            )
            await save(config)
            await restore(config)
            return config

        case .stdioPackage(let packageName, let registryType, let secretEnvNames, let plainEnvNames, _):
            let inputs = plainEnvNames.map { RegistryServer.LaunchInput(name: $0, isRequired: false, isSecret: false) }
                + secretEnvNames.map { RegistryServer.LaunchInput(name: $0, isRequired: true, isSecret: true) }
            let pkg = RegistryServer.Package(registryType: registryType, identifier: packageName, environmentVariables: inputs)
            let config = ConnectorConfiguration(
                serverID: "stdio:\(spec.id)",
                displayName: spec.name,
                package: pkg,
                launchValues: [:],
                secretNames: Set(secretEnvNames)
            )
            await save(config)
            await restore(config)
            return config

        case .customWebhook, .customMCP:
            return nil
        }
    }

    func add(_ server: RegistryServer, preferPhone: Bool = true, launchValues: [String: String] = [:], secretValues: [String: String] = [:]) async {
        if preferPhone, let remote = server.preferredRemote { await addRemote(name: server.displayName, serverID: server.name, endpoint: remote.url) }
        else if let package = server.packages.first(where: \.isAutonomousCompatible) {
            await addStdio(name: server.displayName, serverID: server.name, package: package, launchValues: launchValues, secretValues: secretValues)
        }
    }

    func addCustom(name: String, urlText: String, token: String = "", headerName: String = "") async throws {
        guard let url = URL(string: urlText.trimmingCharacters(in: .whitespacesAndNewlines)),
              (try? OAuthURLPolicy.validate(url)) != nil, let host = url.host else {
            throw MCPAuthorizationError.insecureURL
        }
        let cleanHeader = headerName.trimmingCharacters(in: .whitespacesAndNewlines)
        let config = ConnectorConfiguration(
            serverID: "custom:\(url.absoluteString)",
            displayName: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? host : name.trimmingCharacters(in: .whitespacesAndNewlines),
            endpoint: url,
            authHeaderName: cleanHeader.isEmpty ? nil : cleanHeader
        )
        let cleanToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanToken.isEmpty {
            Keychain.setValue(ConnectorCredential(accessToken: cleanToken, clientID: "manual-token"), account: credentialKey(config.id))
        }
        await save(config)
        await restore(config)
    }

    func addWebhook(name: String, urlText: String, method: String = "POST", headerName: String = "", secret: String = "") async throws {
        guard let url = URL(string: urlText.trimmingCharacters(in: .whitespacesAndNewlines)),
              (try? OAuthURLPolicy.validate(url)) != nil, let host = url.host else {
            throw MCPAuthorizationError.insecureURL
        }
        let cleanHeader = headerName.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanSecret = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        let config = ConnectorConfiguration(
            serverID: "webhook:\(UUID().uuidString.lowercased())",
            displayName: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Webhook (\(host))" : name.trimmingCharacters(in: .whitespacesAndNewlines),
            kind: .webhook,
            endpoint: url,
            secretNames: cleanSecret.isEmpty ? [] : ["webhook_secret"],
            authHeaderName: cleanHeader.isEmpty ? nil : cleanHeader,
            webhookMethod: method.uppercased()
        )
        if !cleanSecret.isEmpty {
            Keychain.set(Data(cleanSecret.utf8), account: builtinSecretKey(config.id))
        }
        await save(config)
        await restore(config)
    }

    func saveRemoteToken(_ token: String, headerName: String?, for configuration: ConnectorConfiguration) async {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        await sessions[configuration.id]?.disconnect()
        sessions[configuration.id] = nil
        Keychain.setValue(ConnectorCredential(accessToken: trimmed, clientID: "manual-token"), account: credentialKey(configuration.id))
        var updated = configuration
        let cleanHeader = headerName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        updated.authHeaderName = cleanHeader.isEmpty ? nil : cleanHeader
        await save(updated)
        await restore(updated)
    }

    func saveBuiltinCredentials(secret: String, extraKey: String?, extraValue: String?, for configuration: ConnectorConfiguration) async {
        let trimmedSecret = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSecret.isEmpty {
            Keychain.set(Data(trimmedSecret.utf8), account: builtinSecretKey(configuration.id))
        }
        var updated = configuration
        if let extraKey, !extraKey.isEmpty {
            let val = (extraValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            updated.launchValues["extra_key"] = extraKey
            updated.launchValues["extra_value"] = val
            updated.launchValues[extraKey] = val
        }
        await save(updated)
        await restore(updated)
    }

    func saveStdioInputs(launchValues: [String: String], secretValues: [String: String], for configuration: ConnectorConfiguration) async {
        var updated = configuration
        for (k, v) in launchValues {
            updated.launchValues[k] = v.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        for (k, v) in secretValues {
            let clean = v.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else { continue }
            updated.secretNames.insert(k)
            Keychain.set(Data(clean.utf8), account: stdioSecretKey(configuration.id, name: k))
        }
        await save(updated)
        await restore(updated)
    }

    func hasStoredBuiltinSecret(_ configuration: ConnectorConfiguration) -> Bool {
        if let data = Keychain.data(account: builtinSecretKey(configuration.id)), !data.isEmpty { return true }
        return false
    }

    func hasStoredStdioSecret(_ configuration: ConnectorConfiguration, name: String) -> Bool {
        if let data = Keychain.data(account: stdioSecretKey(configuration.id, name: name)), !data.isEmpty { return true }
        return false
    }

    private func addRemote(name: String, serverID: String, endpoint: URL) async {
        let configuration = ConnectorConfiguration(serverID: serverID, displayName: name, endpoint: endpoint)
        await save(configuration); await restore(configuration)
    }

    private func addStdio(name: String, serverID: String, package: RegistryServer.Package, launchValues: [String: String], secretValues: [String: String]) async {
        let configuration = ConnectorConfiguration(
            serverID: serverID, displayName: name, package: package,
            launchValues: launchValues, secretNames: Set(package.launchInputs.filter(\.isSecret).map(\.name))
        )
        for (key, value) in secretValues where !value.isEmpty {
            Keychain.set(Data(value.utf8), account: stdioSecretKey(configuration.id, name: key))
        }
        await save(configuration)
        await restore(configuration)
    }

    private func save(_ configuration: ConnectorConfiguration) async {
        guard let data = try? JSONCoding.encoder().encode(configuration), let json = JSONValue.parse(data) else { return }
        let record = ConnectorRecord(id: configuration.id, serverID: configuration.serverID, displayName: configuration.displayName, configuration: json)
        try? await store.save(record)
        connected.removeAll { $0.id == configuration.id }; connected.append(configuration)
        connected.sort { $0.displayName < $1.displayName }
        app?.sync.request()
        await app?.jobs.reconcileAutonomousConnectorSecrets()
    }

    private func restore(_ configuration: ConnectorConfiguration) async {
        switch configuration.kind {
        case .apple:
            let defs = AppleDeviceIntegrations.definitions(for: configuration)
            toolDefinitions[configuration.id] = defs
            states[configuration.id] = .connected
            errors[configuration.id] = nil

        case .webhook:
            toolDefinitions[configuration.id] = BuiltinIntegrationFactory.definitions(for: configuration)
            states[configuration.id] = .connected
            errors[configuration.id] = nil

        case .builtin:
            let defs = BuiltinIntegrationFactory.definitions(for: configuration)
            toolDefinitions[configuration.id] = defs
            let needsSecret = configuration.secretNames.contains("api_key")
            let provider = configuration.launchValues["provider"] ?? ""
            let optionalSecretProviders: Set<String> = ["whatsapp", "loom", "jina", "jina_reader"]
            let githubAccountReady = (provider == "github" && app?.github.isConnected == true)
            if !needsSecret || hasStoredBuiltinSecret(configuration) || optionalSecretProviders.contains(provider) || githubAccountReady {
                states[configuration.id] = .connected
                errors[configuration.id] = nil
            } else {
                states[configuration.id] = .authorizationNeeded
                errors[configuration.id] = nil
            }

        case .stdio:
            toolDefinitions[configuration.id] = BuiltinIntegrationFactory.definitions(for: configuration)
            let missingRequiredSecret = configuration.secretNames.contains { !hasStoredStdioSecret(configuration, name: $0) }
            if missingRequiredSecret {
                states[configuration.id] = .authorizationNeeded
            } else {
                states[configuration.id] = .connected
            }
            errors[configuration.id] = nil

        case .remote:
            states[configuration.id] = .connecting
            let credential = Keychain.value(ConnectorCredential.self, account: credentialKey(configuration.id))
            let session = MCPConnectorSession(
                configuration: configuration,
                credential: credential,
                refreshCredential: { [weak self] current in
                    guard let self else { throw MCPAuthorizationError.rejected("The connector is no longer available.") }
                    return try await self.refreshCredential(current, for: configuration)
                },
                upgradeScopes: { [weak self] current, scopes in
                    guard let self else { throw MCPAuthorizationError.rejected("The connector is no longer available.") }
                    return try await self.upgradeCredential(current, scopes: scopes, for: configuration)
                }
            )
            sessions[configuration.id] = session
            do {
                let tools = try await session.tools()
                toolDefinitions[configuration.id] = tools; states[configuration.id] = .connected; errors[configuration.id] = nil
            } catch {
                states[configuration.id] = credential == nil ? .authorizationNeeded : .failed
                errors[configuration.id] = ErrorExplainer.explain(error).message
            }
        }
    }

    func authorize(_ configuration: ConnectorConfiguration, dynamicRegistration: Bool = false, scopes: Set<String> = []) async {
        if configuration.kind == .apple {
            let key = configuration.launchValues["apple_key"] ?? ""
            let granted = (try? await AppleDeviceIntegrations.requestAuthorization(for: key)) ?? false
            states[configuration.id] = granted ? .connected : .authorizationNeeded
            errors[configuration.id] = granted ? nil : "Enable access for MAIPA-G in iOS Settings."
            return
        }
        guard let endpoint = configuration.endpoint else { return }
        states[configuration.id] = .connecting; errors[configuration.id] = nil
        do {
            let oauth = MCPOAuthClient(transport: transport)
            var registered: MCPRegisteredClient?
            if dynamicRegistration {
                let (_, server) = try await oauth.discover(endpoint: endpoint)
                guard let registration = server.registrationEndpoint else { throw MCPAuthorizationError.registrationRequired }
                registered = try await oauth.register(at: registration)
            }
            let request = try await oauth.authorizationRequest(endpoint: endpoint, requestedScopes: scopes, registeredClient: registered)
            let callback = try await WebSignIn.shared.open(request.url)
            guard OAuthURLPolicy.isExpectedCallback(callback, expected: MCPOAuthClient.appCallbackURL) else {
                throw MCPAuthorizationError.rejected("The connector returned to an unexpected app address.")
            }
            let values = WebSignIn.values(in: callback)
            guard let code = values["code"] else { throw MCPAuthorizationError.rejected(values["error_description"] ?? "The connector did not return a sign-in code.") }
            let credential = try await oauth.exchange(code: code, callbackState: values["state"], request: request)
            Keychain.setValue(credential, account: credentialKey(configuration.id))
            var updated = configuration
            updated.scopes = credential.scopes
            await save(updated)
            await restore(updated)
        } catch WebSignIn.Failure.cancelled { states[configuration.id] = .authorizationNeeded }
        catch {
            if !dynamicRegistration {
                await authorize(configuration, dynamicRegistration: true, scopes: scopes)
                return
            }
            states[configuration.id] = .failed; errors[configuration.id] = ErrorExplainer.explain(error).message
        }
    }

    func reauthorize(_ configuration: ConnectorConfiguration, scopes: Set<String>) async {
        guard let endpoint = configuration.endpoint else { return }
        let discovered = try? await MCPOAuthClient(transport: transport).discover(endpoint: endpoint)
        let available = discovered.map { $0.0.scopesSupported.union($0.1.scopesSupported) } ?? []
        await authorize(configuration, scopes: configuration.scopes.union(scopes).union(available))
    }

    func recheck(_ configuration: ConnectorConfiguration) async {
        await restore(configuration)
    }

    func disconnect(_ configuration: ConnectorConfiguration) async {
        await sessions[configuration.id]?.disconnect(); sessions[configuration.id] = nil
        Keychain.remove(account: credentialKey(configuration.id))
        Keychain.remove(account: builtinSecretKey(configuration.id))
        states[configuration.id] = .disconnected
    }

    func remove(_ configuration: ConnectorConfiguration) async {
        await disconnect(configuration); try? await store.delete(configuration.id)
        for name in configuration.secretNames { Keychain.remove(account: stdioSecretKey(configuration.id, name: name)) }
        await app?.jobs.reconcileAutonomousConnectorSecrets()
        toolDefinitions[configuration.id] = nil
        connected.removeAll { $0.id == configuration.id }; app?.sync.request()
    }

    func autonomousSecretsJSON() -> String? {
        var values: [String: String] = [:]
        for configuration in connected where configuration.kind == .stdio {
            for name in configuration.secretNames {
                if let data = Keychain.data(account: stdioSecretKey(configuration.id, name: name)) {
                    values[configuration.id.uuidString.lowercased() + "." + name] = String(decoding: data, as: UTF8.self)
                }
            }
        }
        if let providers = app?.openRouter.readyExternalProviders, !providers.isEmpty,
           let providerData = try? JSONCoding.encoder().encode(providers) {
            values["__ai_providers_json"] = String(decoding: providerData, as: UTF8.self)
        }
        guard !values.isEmpty, let data = try? JSONEncoder().encode(values) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    func setTool(_ name: String, enabled: Bool, for configuration: ConnectorConfiguration) async {
        var copy = configuration
        if enabled { copy.disabledTools.remove(name) }
        else { copy.disabledTools.insert(name) }
        await save(copy)
    }

    func agentTools() -> [any AgentTool] {
        let computerConn = computerConnector()
        let computerID = computerConn?.id
        let rate = app?.settings.chatComputerHourlyCost
        let control = computerControl()

        return connected.flatMap { configuration -> [any AgentTool] in
            guard states[configuration.id] == .connected else { return [] }
            switch configuration.kind {
            case .remote:
                guard let session = sessions[configuration.id] else { return [] }
                return (toolDefinitions[configuration.id] ?? [])
                    .filter { !configuration.disabledTools.contains($0.originalName) }
                    .map { MCPTool(definition: $0, session: session, computerHourlyRate: configuration.id == computerID ? rate : nil) }
            case .apple:
                return AppleDeviceIntegrations.tools(for: configuration)
            case .builtin, .webhook:
                let storedSecret = Keychain.data(account: builtinSecretKey(configuration.id)).map { String(decoding: $0, as: UTF8.self) }
                let provider = configuration.launchValues["provider"] ?? ""
                if provider == "github", (storedSecret == nil || storedSecret?.isEmpty == true || storedSecret == "__maipag_github_app__") {
                    let ghSession = app?.github.session
                    let fallbackUserToken = Keychain.value(GitHubUserToken.self, for: .githubUserToken)?.accessToken
                    let baseDefs = BuiltinIntegrationFactory.tools(for: configuration, secret: nil, transport: transport, computer: control)
                    return baseDefs.map { baseTool in
                        DynamicGitHubConnectorTool(
                            base: baseTool,
                            configuration: configuration,
                            transport: transport,
                            computer: control,
                            session: ghSession,
                            fallbackUserToken: fallbackUserToken
                        )
                    }
                }
                return BuiltinIntegrationFactory.tools(for: configuration, secret: storedSecret, transport: transport, computer: control)
            case .stdio:
                var envSecrets: [String: String] = [:]
                for name in configuration.secretNames {
                    if let data = Keychain.data(account: stdioSecretKey(configuration.id, name: name)) {
                        envSecrets[name] = String(decoding: data, as: UTF8.self)
                    }
                }
                return BuiltinIntegrationFactory.tools(for: configuration, secret: nil, transport: transport, computer: control, stdioEnvSecrets: envSecrets)
            }
        }
    }

    func computerConnector() -> ConnectorConfiguration? {
        guard let settings = app?.settings, !settings.chatComputerOff else { return nil }
        let ready = connected.filter { $0.kind == .remote && states[$0.id] == .connected }
        if let chosen = settings.chatComputerServer {
            return ready.first { $0.serverID == chosen && canRunCommands($0) }
        }
        return ready.first { connector in
            guard let host = connector.endpoint?.host?.lowercased() else { return false }
            return host == "sprites.dev" || host.hasSuffix(".sprites.dev")
        } ?? ready.first(where: canRunCommands)
    }

    func canRunCommands(_ configuration: ConnectorConfiguration) -> Bool {
        guard configuration.kind == .remote else { return false }
        if let tools = toolDefinitions[configuration.id], !tools.isEmpty { return ComputerControl.hasCommandTool(tools) }
        guard let host = configuration.endpoint?.host?.lowercased() else { return false }
        return host == "sprites.dev" || host.hasSuffix(".sprites.dev")
    }

    func computerControl() -> ComputerControl? {
        guard let configuration = computerConnector(), let session = sessions[configuration.id], let machine = app?.settings.chatComputerMachineName else { return nil }
        return ComputerControl(tools: toolDefinitions[configuration.id] ?? [], machine: machine) { name, arguments in
            try await session.call(tool: name, arguments: arguments)
        }
    }

    static func toolsReadyDefaultsKey(_ machine: String) -> String { "computerToolsReady.\(machine)" }

    func keepComputerAwakeDuringSetup(resetReadyCache: Bool = false) {
        if resetReadyCache, let machine = app?.settings.chatComputerMachineName {
            UserDefaults.standard.removeObject(forKey: Self.toolsReadyDefaultsKey(machine))
        }
        guard setupKeepAwakeTask == nil, !PreviewScenes.isActive else { return }
        setupKeepAwakeTask = Task { @MainActor [weak self] in
            defer { self?.setupKeepAwakeTask = nil }
            let deadline = Date().addingTimeInterval(45 * 60)
            while !Task.isCancelled, Date() < deadline {
                guard let self, self.app?.settings.chatComputerOff == false,
                      let control = self.computerControl(), control.commandTool != nil else { return }
                do {
                    let output = try await control.healthCheck()
                    let state = ComputerControl.toolState(output)
                    if state == .ready, ComputerControl.failedTools(output) == nil {
                        UserDefaults.standard.set(true, forKey: Self.toolsReadyDefaultsKey(control.machine))
                    }
                    guard state == .installing else { return }
                } catch {
                    return
                }
                try? await Task.sleep(nanoseconds: 20_000_000_000)
            }
        }
    }

    private func upgradeCredential(_ credential: ConnectorCredential, scopes: Set<String>, for configuration: ConnectorConfiguration) async throws -> ConnectorCredential {
        guard let endpoint = configuration.endpoint else { throw MCPAuthorizationError.insecureURL }
        let oauth = MCPOAuthClient(transport: transport)
        let client = MCPRegisteredClient(clientID: credential.clientID, clientSecret: credential.clientSecret)
        let request = try await oauth.authorizationRequest(endpoint: endpoint, requestedScopes: credential.scopes.union(scopes), registeredClient: client)
        let callback = try await WebSignIn.shared.open(request.url)
        let values = WebSignIn.values(in: callback)
        guard let code = values["code"] else { throw MCPAuthorizationError.rejected(values["error_description"] ?? "The connector did not grant the extra permission.") }
        var updated = try await oauth.exchange(code: code, callbackState: values["state"], request: request)
        if updated.refreshToken == nil { updated.refreshToken = credential.refreshToken }
        Keychain.setValue(updated, account: credentialKey(configuration.id))
        var copy = configuration
        copy.scopes = updated.scopes
        await save(copy)
        return updated
    }

    private func refreshCredential(_ credential: ConnectorCredential, for configuration: ConnectorConfiguration) async throws -> ConnectorCredential {
        guard let endpoint = configuration.endpoint, credential.refreshToken != nil else { return credential }
        let oauth = MCPOAuthClient(transport: transport)
        let (resource, server) = try await oauth.discover(endpoint: endpoint)
        let updated = try await oauth.refresh(credential, server: server, resource: resource.resource)
        Keychain.setValue(updated, account: credentialKey(configuration.id))
        if updated.scopes != configuration.scopes {
            var copy = configuration
            copy.scopes = updated.scopes
            await save(copy)
        }
        return updated
    }

    private func credentialKey(_ id: UUID) -> String { "mcp.\(id.uuidString.lowercased()).credential" }
    private func builtinSecretKey(_ id: UUID) -> String { "mcp.\(id.uuidString.lowercased()).builtin.secret" }
    private func stdioSecretKey(_ id: UUID, name: String) -> String { "mcp.\(id.uuidString.lowercased()).stdio.\(name)" }

    private static func configuration(_ record: ConnectorRecord) -> ConnectorConfiguration? {
        guard let data = try? JSONCoding.encoder().encode(record.configuration) else { return nil }
        return try? JSONCoding.decoder().decode(ConnectorConfiguration.self, from: data)
    }

    func clearBuiltinSecret(for configuration: ConnectorConfiguration) async {
        Keychain.remove(account: builtinSecretKey(configuration.id))
        await restore(configuration)
    }

    func preview(authNeeded: Bool = false) {
        let item = ConnectorConfiguration(
            serverID: "builtin:github",
            displayName: "GitHub",
            kind: .builtin,
            endpoint: URL(string: "https://api.github.com"),
            launchValues: ["provider": "github", "base_url": "https://api.github.com", "auth_style": "bearer"],
            secretNames: ["api_key"]
        )
        connected = [item]; states[item.id] = authNeeded ? .authorizationNeeded : .connected
        toolDefinitions[item.id] = BuiltinIntegrationFactory.definitions(for: item)
    }
}

private struct DynamicGitHubConnectorTool: AgentTool {
    let base: any AgentTool
    let configuration: ConnectorConfiguration
    let transport: any HTTPTransport
    let computer: ComputerControl?
    let session: GitHubAppSession?
    let fallbackUserToken: String?

    var name: String { base.name }
    var spec: ToolSpec { base.spec }
    var bringsOutsideContent: Bool { base.bringsOutsideContent }

    func runningSummary(for arguments: JSONValue) -> String {
        base.runningSummary(for: arguments)
    }

    func approvalRequest(for arguments: JSONValue) async -> ToolApprovalRequest? {
        await base.approvalRequest(for: arguments)
    }

    func approvalAfterOutsideContent(for arguments: JSONValue) async -> ToolApprovalRequest? {
        await base.approvalAfterOutsideContent(for: arguments)
    }

    func run(arguments: JSONValue, progress: @escaping @Sendable (String) -> Void) async throws -> ToolOutput {
        try await invoke(arguments: arguments, approved: false, progress: progress)
    }

    func runApproved(arguments: JSONValue, progress: @escaping @Sendable (String) -> Void) async throws -> ToolOutput {
        try await invoke(arguments: arguments, approved: true, progress: progress)
    }

    private func invoke(arguments: JSONValue, approved: Bool, progress: @escaping @Sendable (String) -> Void) async throws -> ToolOutput {
        var resolvedToken: String?
        if let session {
            resolvedToken = try? await session.installationToken()
            if resolvedToken == nil {
                resolvedToken = try? await session.userToken()
            }
        }
        if resolvedToken == nil {
            resolvedToken = fallbackUserToken
        }
        let freshTools = BuiltinIntegrationFactory.tools(
            for: configuration,
            secret: resolvedToken,
            transport: transport,
            computer: computer
        )
        guard let matching = freshTools.first(where: { $0.name == base.name }) else {
            return approved
                ? try await base.runApproved(arguments: arguments, progress: progress)
                : try await base.run(arguments: arguments, progress: progress)
        }
        return approved
            ? try await matching.runApproved(arguments: arguments, progress: progress)
            : try await matching.run(arguments: arguments, progress: progress)
    }
}

