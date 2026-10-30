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

    init(transport: any HTTPTransport, paths: AppPaths) {
        self.transport = transport; cacheURL = paths.connectorCatalogue
        store = ProductStore(dataDirectory: paths.data, folder: "connectors")
    }

    func load() async {
        if let data = try? Data(contentsOf: cacheURL), let saved = try? JSONCoding.decoder().decode([RegistryServer].self, from: data) { catalog = saved.sorted(by: MCPRegistryClient.catalogOrder) }
        connected = await store.loadAll().compactMap(Self.configuration).sorted { $0.displayName < $1.displayName }
        for configuration in connected where configuration.kind == .remote { await restore(configuration) }
        if catalog.isEmpty { await search() }
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

    /// Looks up one familiar service without replacing the screen's current catalogue/search.
    /// The UI uses this behind a normal Connect button; the source remains the official Registry.
    func lookup(_ search: String) async throws -> [RegistryServer] {
        let text = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let pages = try await firstPages(for: text)
        let found = Self.ranked(Self.unique(pages.servers), for: text)
        catalog = Self.ranked(Self.unique(catalog + found), for: query.trimmingCharacters(in: .whitespacesAndNewlines))
        try? JSONCoding.encoder().encode(catalog).write(to: cacheURL, options: .atomic)
        return found
    }

    /// The Registry's `search` only matches server names as a substring, so "Hugging Face" finds
    /// nothing while "huggingface" finds `co.huggingface/hf-mcp-server`. This asks for the first
    /// page of up to three spellings at once: as typed, without spaces, and with words joined by
    /// "-". Only the as-typed request has to succeed, and "Load more" continues from its cursor.
    private func firstPages(for text: String) async throws -> (servers: [RegistryServer], nextCursor: String?) {
        let client = MCPRegistryClient(transport: transport)
        let spellings = Self.spellings(of: text)
        async let extra = ConnectorLibrary.bestEffortPages(Array(spellings.dropFirst()), client: client)
        let typed = try await client.page(search: spellings[0], limit: 100)
        let others = await extra
        return (typed.servers + others, typed.nextCursor)
    }

    /// The text as typed first (even when empty, which lists everything), then the other spellings.
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

    /// One entry per server name; a later copy replaces an earlier one.
    nonisolated private static func unique(_ servers: [RegistryServer]) -> [RegistryServer] {
        Array(servers.reduce(into: [String: RegistryServer]()) { $0[$1.name] = $1 }.values)
    }

    /// Entries titled exactly like the query come first (ignoring case, spaces and punctuation),
    /// then the publisher's own entries ("co.huggingface/…" for "Hugging Face"), then the rest,
    /// each group in the Registry's usual order. Among exact titles, the publisher's own entry
    /// leads, so an untitled `io.github.someone/huggingface-mcp` can't push ahead of it.
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

    func add(_ server: RegistryServer, preferPhone: Bool = true, launchValues: [String: String] = [:], secretValues: [String: String] = [:]) async {
        if preferPhone, let remote = server.preferredRemote { await addRemote(name: server.displayName, serverID: server.name, endpoint: remote.url) }
        else if let package = server.packages.first(where: \.isAutonomousCompatible) {
            await addStdio(name: server.displayName, serverID: server.name, package: package, launchValues: launchValues, secretValues: secretValues)
        }
    }

    func addCustom(name: String, urlText: String) async throws {
        guard let url = URL(string: urlText), url.scheme == "https", url.host != nil else { throw MCPAuthorizationError.insecureURL }
        await addRemote(name: name.isEmpty ? url.host! : name, serverID: "custom:\(url.absoluteString)", endpoint: url)
    }

    private func addRemote(name: String, serverID: String, endpoint: URL) async {
        let configuration = ConnectorConfiguration(serverID: serverID, displayName: name, endpoint: endpoint)
        await save(configuration); await restore(configuration)
    }

    private func addStdio(name: String, serverID: String, package: RegistryServer.Package, launchValues: [String: String], secretValues: [String: String]) async {
        let required = package.launchInputs.filter(\.isRequired)
        guard required.allSatisfy({ input in
            let value = input.isSecret ? secretValues[input.name] : launchValues[input.name]
            return value?.isEmpty == false || input.defaultValue != nil
        }) else { return }
        let configuration = ConnectorConfiguration(
            serverID: serverID, displayName: name, package: package,
            launchValues: launchValues, secretNames: Set(package.launchInputs.filter(\.isSecret).map(\.name))
        )
        for (key, value) in secretValues where !value.isEmpty {
            Keychain.set(Data(value.utf8), account: stdioSecretKey(configuration.id, name: key))
        }
        await save(configuration); states[configuration.id] = .disconnected
    }

    private func save(_ configuration: ConnectorConfiguration) async {
        guard let data = try? JSONCoding.encoder().encode(configuration), let json = JSONValue.parse(data) else { return }
        let record = ConnectorRecord(id: configuration.id, serverID: configuration.serverID, displayName: configuration.displayName, configuration: json)
        try? await store.save(record)
        connected.removeAll { $0.id == configuration.id }; connected.append(configuration)
        app?.sync.request()
        await app?.jobs.reconcileAutonomousConnectorSecrets()
    }

    private func restore(_ configuration: ConnectorConfiguration) async {
        guard configuration.kind == .remote else { return }
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

    func authorize(_ configuration: ConnectorConfiguration, dynamicRegistration: Bool = false, scopes: Set<String> = []) async {
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

    func disconnect(_ configuration: ConnectorConfiguration) async {
        await sessions[configuration.id]?.disconnect(); sessions[configuration.id] = nil
        Keychain.remove(account: credentialKey(configuration.id)); toolDefinitions[configuration.id] = nil
        states[configuration.id] = .disconnected
    }

    func remove(_ configuration: ConnectorConfiguration) async {
        await disconnect(configuration); try? await store.delete(configuration.id)
        for name in configuration.secretNames { Keychain.remove(account: stdioSecretKey(configuration.id, name: name)) }
        await app?.jobs.reconcileAutonomousConnectorSecrets()
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
        guard !values.isEmpty, let data = try? JSONEncoder().encode(values) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    func agentTools() -> [any AgentTool] {
        connected.flatMap { configuration -> [any AgentTool] in
            guard states[configuration.id] == .connected, let session = sessions[configuration.id] else { return [] }
            return (toolDefinitions[configuration.id] ?? []).map { MCPTool(definition: $0, session: session) }
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
    private func stdioSecretKey(_ id: UUID, name: String) -> String { "mcp.\(id.uuidString.lowercased()).stdio.\(name)" }

    private static func configuration(_ record: ConnectorRecord) -> ConnectorConfiguration? {
        guard let data = try? JSONCoding.encoder().encode(record.configuration) else { return nil }
        return try? JSONCoding.decoder().decode(ConnectorConfiguration.self, from: data)
    }

    func preview(authNeeded: Bool = false) {
        let item = ConnectorConfiguration(serverID: "com.github/github-mcp", displayName: "GitHub", endpoint: URL(string: "https://api.githubcopilot.com/mcp")!)
        connected = [item]; states[item.id] = authNeeded ? .authorizationNeeded : .connected
        toolDefinitions[item.id] = [ConnectorToolDefinition(serverID: item.serverID, serverName: item.displayName, originalName: "search_repositories", title: "Search repositories", description: "Search GitHub repositories")]
        catalog = [RegistryServer(name: item.serverID, displayName: "GitHub", description: "Work with repositories, issues, and pull requests.", version: "latest", remotes: [.init(type: "streamable-http", url: item.endpoint!)])]
    }
}
