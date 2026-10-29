import Foundation

public enum ConnectorKind: String, Codable, Sendable, Hashable { case remote, stdio }
public enum ConnectorConnectionState: String, Codable, Sendable, Hashable { case disconnected, connecting, authorizationNeeded, connected, failed }

public struct ConnectorConfiguration: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var serverID: String
    public var displayName: String
    public var kind: ConnectorKind
    public var endpoint: URL?
    public var package: RegistryServer.Package?
    public var scopes: Set<String>
    public var createdAt: Date

    public init(id: UUID = UUID(), serverID: String, displayName: String, endpoint: URL) {
        self.id = id; self.serverID = serverID; self.displayName = displayName; kind = .remote
        self.endpoint = endpoint; package = nil; scopes = []; createdAt = Date()
    }

    public init(id: UUID = UUID(), serverID: String, displayName: String, package: RegistryServer.Package) {
        self.id = id; self.serverID = serverID; self.displayName = displayName; kind = .stdio
        endpoint = nil; self.package = package; scopes = []; createdAt = Date()
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

    public init(serverID: String, serverName: String, originalName: String, title: String? = nil, description: String = "", inputSchema: JSONValue = ["type": "object"]) {
        self.serverID = serverID; self.serverName = serverName; self.originalName = originalName
        self.namespacedName = Self.namespace(server: serverName, tool: originalName)
        self.title = title ?? originalName; self.description = description; self.inputSchema = inputSchema
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
    case rejected(String)
    public var description: String {
        switch self {
        case .insecureURL: return "MCP connectors must use HTTPS."
        case .discovery(let value): return "OAuth discovery failed: \(value)"
        case .registrationRequired: return "This connector requires a client ID registered by its owner."
        case .stateMismatch: return "The connector sign-in answer did not match this request."
        case .rejected(let value): return value
        }
    }
}
