import Foundation

public enum ConnectorKind: String, Codable, Sendable, Hashable {
    case remote
    case stdio
    case builtin
    case apple
    case webhook
}
public enum ConnectorConnectionState: String, Codable, Sendable, Hashable { case disconnected, connecting, authorizationNeeded, connected, failed }

public struct ConnectorConfiguration: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var serverID: String
    public var displayName: String
    public var kind: ConnectorKind
    public var endpoint: URL?
    public var package: RegistryServer.Package?
    /// Nonsecret launch values may sync. Secret values are stored only in Keychain.
    public var launchValues: [String: String]
    public var secretNames: Set<String>
    public var scopes: Set<String>
    /// Tool names the owner turned off. Missing in older records means every discovered tool is enabled.
    public var disabledTools: Set<String>
    /// Optional custom HTTP header name for API-key/webhook auth (defaults to Authorization Bearer when nil).
    public var authHeaderName: String?
    /// Optional HTTP method for webhook connectors (defaults to POST).
    public var webhookMethod: String?
    public var createdAt: Date

    public init(id: UUID = UUID(), serverID: String, displayName: String, endpoint: URL, authHeaderName: String? = nil) {
        self.id = id; self.serverID = serverID; self.displayName = displayName; kind = .remote
        self.endpoint = endpoint; package = nil; launchValues = [:]; secretNames = []; scopes = []; disabledTools = []
        self.authHeaderName = authHeaderName; webhookMethod = nil; createdAt = Date()
    }

    public init(id: UUID = UUID(), serverID: String, displayName: String, package: RegistryServer.Package, launchValues: [String: String] = [:], secretNames: Set<String> = []) {
        self.id = id; self.serverID = serverID; self.displayName = displayName; kind = .stdio
        endpoint = nil; self.package = package; self.launchValues = launchValues; self.secretNames = secretNames; scopes = []; disabledTools = []
        authHeaderName = nil; webhookMethod = nil; createdAt = Date()
    }

    public init(
        id: UUID = UUID(),
        serverID: String,
        displayName: String,
        kind: ConnectorKind,
        endpoint: URL? = nil,
        launchValues: [String: String] = [:],
        secretNames: Set<String> = [],
        authHeaderName: String? = nil,
        webhookMethod: String? = nil
    ) {
        self.id = id; self.serverID = serverID; self.displayName = displayName; self.kind = kind
        self.endpoint = endpoint; package = nil; self.launchValues = launchValues; self.secretNames = secretNames
        scopes = []; disabledTools = []; self.authHeaderName = authHeaderName; self.webhookMethod = webhookMethod
        createdAt = Date()
    }

    enum CodingKeys: String, CodingKey {
        case id, serverID, displayName, kind, endpoint, package, launchValues, secretNames, scopes, disabledTools, authHeaderName, webhookMethod, createdAt
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id); serverID = try c.decode(String.self, forKey: .serverID)
        displayName = try c.decode(String.self, forKey: .displayName); kind = try c.decode(ConnectorKind.self, forKey: .kind)
        endpoint = try c.decodeIfPresent(URL.self, forKey: .endpoint); package = try c.decodeIfPresent(RegistryServer.Package.self, forKey: .package)
        launchValues = try c.decodeIfPresent([String: String].self, forKey: .launchValues) ?? [:]
        secretNames = try c.decodeIfPresent(Set<String>.self, forKey: .secretNames) ?? []
        scopes = try c.decodeIfPresent(Set<String>.self, forKey: .scopes) ?? []
        disabledTools = try c.decodeIfPresent(Set<String>.self, forKey: .disabledTools) ?? []
        authHeaderName = try c.decodeIfPresent(String.self, forKey: .authHeaderName)
        webhookMethod = try c.decodeIfPresent(String.self, forKey: .webhookMethod)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }
}

public struct ConnectorCredential: Codable, Sendable, Hashable {
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Date?
    public var clientID: String
    public var clientSecret: String?
    public var scopes: Set<String>
    public init(accessToken: String, refreshToken: String? = nil, expiresAt: Date? = nil, clientID: String, clientSecret: String? = nil, scopes: Set<String> = []) {
        self.accessToken = accessToken; self.refreshToken = refreshToken; self.expiresAt = expiresAt
        self.clientID = clientID; self.clientSecret = clientSecret; self.scopes = scopes
    }

    public func needsRefresh(at now: Date = Date(), margin: TimeInterval = 120) -> Bool {
        guard refreshToken != nil, let expiresAt else { return false }
        return expiresAt.timeIntervalSince(now) <= margin
    }
}

public struct ConnectorToolDefinition: Codable, Sendable, Hashable, Identifiable {
    public var id: String { namespacedName }
    public var serverID: String
    public var serverName: String
    public var originalName: String
    public var namespacedName: String
    public var title: String
    public var description: String
    public var inputSchema: JSONValue
    /// The server's own MCP hints. They can only add an approval, never remove one.
    public var readOnlyHint: Bool?
    public var destructiveHint: Bool?

    public init(serverID: String, serverName: String, originalName: String, title: String? = nil, description: String = "", inputSchema: JSONValue = ["type": "object"], readOnlyHint: Bool? = nil, destructiveHint: Bool? = nil) {
        self.serverID = serverID; self.serverName = serverName; self.originalName = originalName
        self.namespacedName = Self.namespace(server: serverName, tool: originalName)
        self.title = title ?? originalName; self.description = description; self.inputSchema = inputSchema
        self.readOnlyHint = readOnlyHint; self.destructiveHint = destructiveHint
    }

    public static func namespace(server: String, tool: String) -> String {
        func clean(_ value: String) -> String {
            let scalars = value.lowercased().unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character(String($0)) : "_" }
            return String(scalars).split(separator: "_").filter { !$0.isEmpty }.joined(separator: "_")
        }
        return String("mcp_\(clean(server))_\(clean(tool))".prefix(64))
    }
}

public struct MCPProtectedResourceMetadata: Sendable, Hashable {
    public var resource: URL
    public var authorizationServers: [URL]
    public var scopesSupported: Set<String>
}

public struct MCPAuthorizationServerMetadata: Sendable, Hashable {
    public var issuer: URL
    public var authorizationEndpoint: URL
    public var tokenEndpoint: URL
    public var registrationEndpoint: URL?
    public var scopesSupported: Set<String>
}

public struct MCPRegisteredClient: Codable, Sendable, Hashable {
    public var clientID: String
    public var clientSecret: String?
    public init(clientID: String, clientSecret: String? = nil) { self.clientID = clientID; self.clientSecret = clientSecret }
}

public struct MCPAuthorizationRequest: Sendable, Hashable {
    public var url: URL
    public var resource: URL
    public var redirectURI: URL
    public var state: String
    public var pkce: PKCE
    public var server: MCPAuthorizationServerMetadata
    public var client: MCPRegisteredClient
    public var scopes: Set<String>
}

public enum MCPAuthorizationError: Error, Sendable, CustomStringConvertible {
    case insecureURL
    case discovery(String)
    case registrationRequired
    case stateMismatch
    case insufficientScope(Set<String>)
    case rejected(String)
    public var description: String {
        switch self {
        case .insecureURL: return "MCP connectors must use HTTPS."
        case .discovery(let value): return "OAuth discovery failed: \(value)"
        case .registrationRequired: return "This connector requires a client ID registered by its owner."
        case .stateMismatch: return "The connector sign-in answer did not match this request."
        case .insufficientScope(let scopes): return "This connector needs more permission: \(scopes.sorted().joined(separator: ", "))."
        case .rejected(let value): return value
        }
    }
}
