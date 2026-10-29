import Foundation
import MCP
#if os(Linux)
import SystemPackage
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// OAuth discovery, registration and token exchange for remote MCP servers.
public struct MCPOAuthClient: Sendable {
    public static let clientMetadataURL = URL(string: "https://2c2bhdhw9z-cell.github.io/MAIPA-G/mcp/client.json")!
    public static let redirectURI = URL(string: "https://2c2bhdhw9z-cell.github.io/MAIPA-G/mcp/")!
    private let transport: any HTTPTransport
    public init(transport: any HTTPTransport) { self.transport = transport }

    public func discover(endpoint: URL) async throws -> (MCPProtectedResourceMetadata, MCPAuthorizationServerMetadata) {
        guard endpoint.scheme == "https", let host = endpoint.host else { throw MCPAuthorizationError.insecureURL }
        var candidates = [URL(string: "https://\(host)/.well-known/oauth-protected-resource")!]
        if endpoint.path != "/" && !endpoint.path.isEmpty {
            candidates.insert(URL(string: "https://\(host)/.well-known/oauth-protected-resource\(endpoint.path)")!, at: 0)
        }
        var resourceJSON: JSONValue?
        for url in candidates {
            let response = try await transport.send(HTTPRequest(url: url, headers: ["Accept": "application/json"]))
            if response.isSuccess, let json = JSONValue.parse(response.body) { resourceJSON = json; break }
        }
        guard let resourceJSON else { throw MCPAuthorizationError.discovery("The server did not publish protected-resource metadata.") }
        let resource = resourceJSON["resource"]?.stringValue.flatMap(URL.init(string:)) ?? endpoint
        let authorizationServers = (resourceJSON["authorization_servers"]?.arrayValue ?? []).compactMap { $0.stringValue.flatMap(URL.init(string:)) }
        guard let issuer = authorizationServers.first else { throw MCPAuthorizationError.discovery("No authorization server was listed.") }
        let resourceMetadata = MCPProtectedResourceMetadata(resource: resource, authorizationServers: authorizationServers, scopesSupported: Set(resourceJSON["scopes_supported"]?.arrayValue?.compactMap(\.stringValue) ?? []))

        let metadataURL = try authorizationMetadataURL(issuer)
        let response = try await transport.send(HTTPRequest(url: metadataURL, headers: ["Accept": "application/json"]))
        guard response.isSuccess, let json = JSONValue.parse(response.body),
              let authorization = json["authorization_endpoint"]?.stringValue.flatMap(URL.init(string:)),
              let token = json["token_endpoint"]?.stringValue.flatMap(URL.init(string:))
        else { throw MCPAuthorizationError.discovery("The authorization server metadata was incomplete.") }
        let serverMetadata = MCPAuthorizationServerMetadata(
            issuer: json["issuer"]?.stringValue.flatMap(URL.init(string:)) ?? issuer,
            authorizationEndpoint: authorization,
            tokenEndpoint: token,
            registrationEndpoint: json["registration_endpoint"]?.stringValue.flatMap(URL.init(string:)),
            scopesSupported: Set(json["scopes_supported"]?.arrayValue?.compactMap(\.stringValue) ?? [])
        )
        return (resourceMetadata, serverMetadata)
    }

    private func authorizationMetadataURL(_ issuer: URL) throws -> URL {
        guard issuer.scheme == "https", let host = issuer.host else { throw MCPAuthorizationError.insecureURL }
        let path = issuer.path == "/" ? "" : issuer.path
        return URL(string: "https://\(host)/.well-known/oauth-authorization-server\(path)")!
    }

    /// Registers only when Client ID Metadata Documents are not accepted by the server.
    public func register(at endpoint: URL, redirectURI: URL = Self.redirectURI) async throws -> MCPRegisteredClient {
        let body: JSONValue = [
            "client_name": "MAIPA-G",
            "client_uri": .string(OpenRouterClient.appURL),
            "redirect_uris": [.string(redirectURI.absoluteString)],
            "grant_types": ["authorization_code", "refresh_token"],
            "response_types": ["code"],
            "token_endpoint_auth_method": "none",
        ]
        let request = try HTTPRequest.json("POST", endpoint, body: body, headers: ["Accept": "application/json"])
        let response = try await transport.send(request)
        guard response.isSuccess, let json = JSONValue.parse(response.body), let id = json["client_id"]?.stringValue else {
            throw MCPAuthorizationError.rejected(response.text.isEmpty ? "The connector did not accept dynamic registration." : response.text)
        }
        return MCPRegisteredClient(clientID: id, clientSecret: json["client_secret"]?.stringValue)
    }

    public func authorizationRequest(endpoint: URL, requestedScopes: Set<String> = [], registeredClient: MCPRegisteredClient? = nil, redirectURI: URL = Self.redirectURI) async throws -> MCPAuthorizationRequest {
        let (resource, server) = try await discover(endpoint: endpoint)
        let client: MCPRegisteredClient
        if let registeredClient { client = registeredClient }
        else {
            // RFC 7591 allows an HTTPS metadata document URL as the public client identifier.
            client = MCPRegisteredClient(clientID: Self.clientMetadataURL.absoluteString)
        }
        let scopes = requestedScopes.isEmpty ? (resource.scopesSupported.isEmpty ? server.scopesSupported : resource.scopesSupported) : requestedScopes
        let state = Hashing.randomToken()
        let pkce = PKCE()
        var components = URLComponents(url: server.authorizationEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: client.clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI.absoluteString),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "resource", value: resource.resource.absoluteString),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        if !scopes.isEmpty { components.queryItems?.append(URLQueryItem(name: "scope", value: scopes.sorted().joined(separator: " "))) }
        guard let url = components.url else { throw MCPAuthorizationError.discovery("The authorization URL was invalid.") }
        return MCPAuthorizationRequest(url: url, resource: resource.resource, redirectURI: redirectURI, state: state, pkce: pkce, server: server, client: client, scopes: scopes)
    }

    public func exchange(code: String, callbackState: String?, request authorization: MCPAuthorizationRequest) async throws -> ConnectorCredential {
        guard callbackState == authorization.state else { throw MCPAuthorizationError.stateMismatch }
        var fields = [
            "grant_type": "authorization_code", "code": code,
            "redirect_uri": authorization.redirectURI.absoluteString,
            "client_id": authorization.client.clientID,
            "code_verifier": authorization.pkce.verifier,
            "resource": authorization.resource.absoluteString,
        ]
        if let secret = authorization.client.clientSecret { fields["client_secret"] = secret }
        var credential = try await tokenRequest(authorization.server.tokenEndpoint, fields: fields, client: authorization.client)
        if credential.scopes.isEmpty { credential.scopes = authorization.scopes }
        return credential
    }

    public func refresh(_ credential: ConnectorCredential, server: MCPAuthorizationServerMetadata, resource: URL) async throws -> ConnectorCredential {
        guard let refresh = credential.refreshToken else { return credential }
        var fields = ["grant_type": "refresh_token", "refresh_token": refresh, "client_id": credential.clientID, "resource": resource.absoluteString]
        if let secret = credential.clientSecret { fields["client_secret"] = secret }
        var updated = try await tokenRequest(server.tokenEndpoint, fields: fields, client: MCPRegisteredClient(clientID: credential.clientID, clientSecret: credential.clientSecret))
        if updated.refreshToken == nil { updated.refreshToken = refresh }
        if updated.scopes.isEmpty { updated.scopes = credential.scopes }
        return updated
    }

    private func tokenRequest(_ endpoint: URL, fields: [String: String], client: MCPRegisteredClient) async throws -> ConnectorCredential {
        let body = fields.sorted { $0.key < $1.key }.map { "\(Self.form($0.key))=\(Self.form($0.value))" }.joined(separator: "&")
        let response = try await transport.send(HTTPRequest(method: "POST", url: endpoint, headers: ["Accept": "application/json", "Content-Type": "application/x-www-form-urlencoded"], body: Data(body.utf8)))
        guard response.isSuccess, let json = JSONValue.parse(response.body), let token = json["access_token"]?.stringValue else {
            throw MCPAuthorizationError.rejected(response.text.isEmpty ? "The connector did not return an access token." : response.text)
        }
        let scopes = Set((json["scope"]?.stringValue ?? "").split(separator: " ").map(String.init))
        return ConnectorCredential(accessToken: token, refreshToken: json["refresh_token"]?.stringValue, expiresAt: json["expires_in"]?.doubleValue.map { Date().addingTimeInterval($0) }, clientID: client.clientID, clientSecret: client.clientSecret, scopes: scopes)
    }

    private static func form(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics; allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

/// A live remote MCP connection backed by the official Swift SDK's Streamable HTTP transport.
public actor MCPConnectorSession {
    public typealias CredentialRefresher = @Sendable (ConnectorCredential) async throws -> ConnectorCredential
    public typealias ScopeUpgrader = @Sendable (ConnectorCredential, Set<String>) async throws -> ConnectorCredential

    public let configuration: ConnectorConfiguration
    private var credential: ConnectorCredential?
    private let refreshCredential: CredentialRefresher?
    private let upgradeScopes: ScopeUpgrader?
    private var client = Client(name: "MAIPA-G", version: "0.1.0", title: "MAIPA-G", websiteUrl: OpenRouterClient.appURL)
    private var transport: HTTPClientTransport?
    private var connected = false

    public init(configuration: ConnectorConfiguration, credential: ConnectorCredential? = nil, refreshCredential: CredentialRefresher? = nil, upgradeScopes: ScopeUpgrader? = nil) {
        self.configuration = configuration; self.credential = credential; self.refreshCredential = refreshCredential; self.upgradeScopes = upgradeScopes
    }

    public func connect() async throws {
        if connected { return }
        try await refreshIfNeeded(force: false)
        guard let endpoint = configuration.endpoint, endpoint.scheme == "https" else { throw MCPAuthorizationError.insecureURL }
        let token = credential?.accessToken
        let transport = HTTPClientTransport(endpoint: endpoint, configuration: .ephemeral, streaming: true) { request in
            var request = request
            if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            return request
        }
        _ = try await client.connect(transport: transport)
        self.transport = transport; connected = true
    }

    public func disconnect() async { await client.disconnect(); transport = nil; connected = false }

    public func tools() async throws -> [ConnectorToolDefinition] {
        do { return try await listTools() }
        catch {
            if let required = Self.requiredScopes(from: error), !required.isEmpty {
                try await authorizeAdditionalScopes(required)
                return try await listTools()
            }
            if Self.isAuthorizationFailure(error), credential?.refreshToken != nil {
                try await refreshIfNeeded(force: true)
                return try await listTools()
            }
            throw error
        }
    }

    private func listTools() async throws -> [ConnectorToolDefinition] {
        if !connected { try await connect() }
        var cursor: String?
        var output: [ConnectorToolDefinition] = []
        repeat {
            let page = try await client.listTools(cursor: cursor)
            for tool in page.tools {
                let schema = (try? JSONValue.parse(JSONEncoder().encode(tool.inputSchema))) ?? ["type": "object"]
                output.append(ConnectorToolDefinition(serverID: configuration.serverID, serverName: configuration.displayName, originalName: tool.name, title: tool.title, description: tool.description ?? "", inputSchema: schema))
            }
            cursor = page.nextCursor
        } while cursor != nil
        return output
    }

    public func call(tool name: String, arguments: JSONValue) async throws -> (text: String, isError: Bool) {
        do { return try await callOnce(tool: name, arguments: arguments) }
        catch {
            if let required = Self.requiredScopes(from: error), !required.isEmpty {
                try await authorizeAdditionalScopes(required)
                return try await callOnce(tool: name, arguments: arguments)
            }
            if Self.isAuthorizationFailure(error), credential?.refreshToken != nil {
                try await refreshIfNeeded(force: true)
                return try await callOnce(tool: name, arguments: arguments)
            }
            throw error
        }
    }

    private func callOnce(tool name: String, arguments: JSONValue) async throws -> (text: String, isError: Bool) {
        if !connected { try await connect() }
        let values = try MCP.Value(arguments).objectValue ?? [:]
        let result = try await client.callTool(name: name, arguments: values)
        let rendered = result.content.map { content -> String in
            switch content {
            case .text(let text, _, _): return text
            case .image(_, let mimeType, _, _): return "[Image returned: \(mimeType)]"
            case .audio(_, let mimeType, _, _): return "[Audio returned: \(mimeType)]"
            case .resource(let resource, _, _): return String(describing: resource)
            case .resourceLink(let uri, let name, _, _, _, _): return "\(name): \(uri)"
            }
        }.joined(separator: "\n")
        return (rendered, result.isError == true)
    }

    private func authorizeAdditionalScopes(_ required: Set<String>) async throws {
        guard let current = credential, let upgradeScopes else { throw MCPAuthorizationError.insufficientScope(required) }
        if connected { await client.disconnect() }
        connected = false; transport = nil
        credential = try await upgradeScopes(current, current.scopes.union(required))
        client = Client(name: "MAIPA-G", version: "0.1.0", title: "MAIPA-G", websiteUrl: OpenRouterClient.appURL)
    }

    public static func requiredScopes(from error: Error) -> Set<String>? {
        let text = String(describing: error)
        guard text.lowercased().contains("insufficient_scope") || text.lowercased().contains("insufficient scope") else { return nil }
        let patterns = [#"scope\s*=\s*\"([^\"]+)\""#, #"required_scopes?[\"']?\s*[:=]\s*[\"']([^\"']+)"#]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), match.numberOfRanges > 1,
                  let range = Range(match.range(at: 1), in: text) else { continue }
            let values = text[range].split(whereSeparator: { $0.isWhitespace || $0 == "," }).map(String.init)
            if !values.isEmpty { return Set(values) }
        }
        return []
    }

    private func refreshIfNeeded(force: Bool) async throws {
        guard let credential, let refreshCredential,
              force || credential.needsRefresh() else { return }
        if connected { await client.disconnect() }
        connected = false; transport = nil
        self.credential = try await refreshCredential(credential)
        client = Client(name: "MAIPA-G", version: "0.1.0", title: "MAIPA-G", websiteUrl: OpenRouterClient.appURL)
    }

    private static func isAuthorizationFailure(_ error: Error) -> Bool {
        let text = String(describing: error).lowercased()
        return text.contains("401") || text.contains("unauthorized") || text.contains("authorization") || text.contains("invalid token")
    }
}

#if os(Linux)
/// Runs Registry stdio packages only in the Autonomous Linux runner.
public actor AutonomousStdioConnector {
    private let configuration: ConnectorConfiguration
    private let client = Client(name: "MAIPAGRunner", version: "0.1.0")
    private var process: Process?

    public init(configuration: ConnectorConfiguration) { self.configuration = configuration }

    public func connect(environment: [String: String] = [:]) async throws -> [ConnectorToolDefinition] {
        guard configuration.kind == .stdio, let package = configuration.package else { throw ToolInputError("This is not a stdio connector.") }
        let supplied = configuration.launchValues.merging(environment) { _, secret in secret }
        let command = try Self.command(for: package, values: supplied)
        let process = Process()
        let input = Pipe(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = command
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        let inherited = BoundedProcess.sanitizedEnvironment(ProcessInfo.processInfo.environment)
        let declaredEnvironment = Dictionary(uniqueKeysWithValues: package.environmentVariables.compactMap { input -> (String, String)? in
            let value = supplied[input.name] ?? input.defaultValue
            return value.map { (input.name, $0) }
        })
        for input in package.environmentVariables {
            if input.isRequired && declaredEnvironment[input.name]?.isEmpty != false {
                throw ToolInputError("\(input.name) is required to start this connector.")
            }
            if let value = declaredEnvironment[input.name], !input.choices.isEmpty, !input.choices.contains(value) {
                throw ToolInputError("\(input.name) must use a declared choice.")
            }
        }
        process.environment = inherited.merging(declaredEnvironment) { _, supplied in supplied }
        try process.run()
        let transport = StdioTransport(
            input: FileDescriptor(rawValue: output.fileHandleForReading.fileDescriptor),
            output: FileDescriptor(rawValue: input.fileHandleForWriting.fileDescriptor)
        )
        _ = try await client.connect(transport: transport)
        self.process = process
        var definitions: [ConnectorToolDefinition] = []
        var cursor: String?
        repeat {
            let page = try await client.listTools(cursor: cursor)
            definitions += page.tools.map { tool in
                let schema = (try? JSONValue.parse(JSONEncoder().encode(tool.inputSchema))) ?? ["type": "object"]
                return ConnectorToolDefinition(serverID: configuration.serverID, serverName: configuration.displayName, originalName: tool.name, title: tool.title, description: tool.description ?? "", inputSchema: schema)
            }
            cursor = page.nextCursor
        } while cursor != nil
        return definitions
    }

    public func call(tool: String, arguments: JSONValue) async throws -> String {
        let result = try await client.callTool(name: tool, arguments: try MCP.Value(arguments).objectValue ?? [:])
        return result.content.map(String.init(describing:)).joined(separator: "\n")
    }

    public func disconnect() async {
        await client.disconnect()
        process?.terminate(); process = nil
    }

    static func command(for package: RegistryServer.Package, values: [String: String] = [:]) throws -> [String] {
        guard package.isAutonomousCompatible else { throw ToolInputError("Autonomous does not support this package transport or runtime.") }
        guard !package.identifier.isEmpty, !package.identifier.contains("\n"), !package.identifier.contains("\0") else { throw ToolInputError("The Registry package identifier is invalid.") }
        let versioned = package.version.map { "\(package.identifier)@\($0)" } ?? package.identifier
        let runtimeArguments = try package.runtimeArguments.flatMap { try $0.rendered(values: values) }
        let packageArguments = try package.packageArguments.flatMap { try $0.rendered(values: values) }
        switch package.registryType.lowercased() {
        case "npm": return ["npx", "--yes"] + runtimeArguments + [versioned] + packageArguments
        case "pypi": return ["uvx"] + runtimeArguments + [package.version.map { "\(package.identifier)==\($0)" } ?? package.identifier] + packageArguments
        default: throw ToolInputError("Autonomous does not support the \(package.registryType) package runtime.")
        }
    }
}

/// One discovered stdio connector tool backed by the official SDK session on Autonomous Linux.
public struct AutonomousMCPTool: AgentTool {
    public let definition: ConnectorToolDefinition
    public let connector: AutonomousStdioConnector
    public var name: String { definition.namespacedName }

    public init(definition: ConnectorToolDefinition, connector: AutonomousStdioConnector) {
        self.definition = definition
        self.connector = connector
    }

    public var spec: ToolSpec {
        ToolSpec(name: name, description: "\(definition.serverName): \(definition.description)", parameters: definition.inputSchema)
    }

    public func runningSummary(for arguments: JSONValue) -> String { "Using \(definition.serverName) · \(definition.title)…" }

    public func run(arguments: JSONValue, progress: @escaping @Sendable (String) -> Void) async throws -> ToolOutput {
        progress("Waiting for \(definition.serverName)…")
        let response = try await connector.call(tool: definition.originalName, arguments: arguments)
        return ToolOutput(forModel: response, summary: "Used \(definition.serverName) · \(definition.title)", detail: response)
    }
}
#endif
