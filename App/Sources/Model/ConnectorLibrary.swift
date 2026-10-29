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
            let page = try await MCPRegistryClient(transport: transport).page(search: query, cursor: reset ? nil : nextCursor)
            catalog = (reset ? page.servers : catalog + page.servers).reduce(into: [String: RegistryServer]()) { $0[$1.name] = $1 }.values.sorted(by: MCPRegistryClient.catalogOrder)
            nextCursor = page.nextCursor
            try? JSONCoding.encoder().encode(catalog).write(to: cacheURL, options: .atomic)
        } catch { if catalog.isEmpty { errors[UUID()] = String(describing: error) } }
    }

    func add(_ server: RegistryServer, preferPhone: Bool = true) async {
        if preferPhone, let remote = server.preferredRemote { await addRemote(name: server.displayName, serverID: server.name, endpoint: remote.url) }
        else if let package = server.packages.first { await addStdio(name: server.displayName, serverID: server.name, package: package) }
    }

    func addCustom(name: String, urlText: String) async throws {
        guard let url = URL(string: urlText), url.scheme == "https", url.host != nil else { throw MCPAuthorizationError.insecureURL }
        await addRemote(name: name.isEmpty ? url.host! : name, serverID: "custom:\(url.absoluteString)", endpoint: url)
    }

    private func addRemote(name: String, serverID: String, endpoint: URL) async {
        let configuration = ConnectorConfiguration(serverID: serverID, displayName: name, endpoint: endpoint)
        await save(configuration); await restore(configuration)
    }

    private func addStdio(name: String, serverID: String, package: RegistryServer.Package) async {
        let configuration = ConnectorConfiguration(serverID: serverID, displayName: name, package: package)
        await save(configuration); states[configuration.id] = .disconnected
    }

    private func save(_ configuration: ConnectorConfiguration) async {
        guard let data = try? JSONCoding.encoder().encode(configuration), let json = JSONValue.parse(data) else { return }
        let record = ConnectorRecord(id: configuration.id, serverID: configuration.serverID, displayName: configuration.displayName, configuration: json)
        try? await store.save(record)
        connected.removeAll { $0.id == configuration.id }; connected.append(configuration)
        app?.sync.request()
    }

    private func restore(_ configuration: ConnectorConfiguration) async {
        guard configuration.kind == .remote else { return }
        states[configuration.id] = .connecting
        let credential = Keychain.value(ConnectorCredential.self, account: credentialKey(configuration.id))
        let session = MCPConnectorSession(configuration: configuration, credential: credential) { [weak self] current in
            guard let self else { throw MCPAuthorizationError.rejected("The connector is no longer available.") }
            return try await self.refreshCredential(current, for: configuration)
        }
        sessions[configuration.id] = session
        do {
            let tools = try await session.tools()
            toolDefinitions[configuration.id] = tools; states[configuration.id] = .connected; errors[configuration.id] = nil
        } catch {
            states[configuration.id] = credential == nil ? .authorizationNeeded : .failed
            errors[configuration.id] = String(describing: error)
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
            states[configuration.id] = .failed; errors[configuration.id] = String(describing: error)
        }
    }

    func reauthorize(_ configuration: ConnectorConfiguration, scopes: Set<String>) async { await authorize(configuration, scopes: scopes) }

    func disconnect(_ configuration: ConnectorConfiguration) async {
        await sessions[configuration.id]?.disconnect(); sessions[configuration.id] = nil
        Keychain.remove(account: credentialKey(configuration.id)); toolDefinitions[configuration.id] = nil
        states[configuration.id] = .disconnected
    }

    func remove(_ configuration: ConnectorConfiguration) async {
        await disconnect(configuration); try? await store.delete(configuration.id)
        connected.removeAll { $0.id == configuration.id }; app?.sync.request()
    }

    func agentTools() -> [any AgentTool] {
        connected.flatMap { configuration -> [any AgentTool] in
            guard states[configuration.id] == .connected, let session = sessions[configuration.id] else { return [] }
            return (toolDefinitions[configuration.id] ?? []).map { MCPTool(definition: $0, session: session) }
        }
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
