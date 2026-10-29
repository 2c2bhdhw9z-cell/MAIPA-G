import Foundation

/// One latest active server from the official MCP Registry.
public struct RegistryServer: Codable, Sendable, Hashable, Identifiable {
    public struct Remote: Codable, Sendable, Hashable {
        public var type: String
        public var url: URL
        public init(type: String, url: URL) { self.type = type; self.url = url }
    }

    public struct LaunchInput: Codable, Sendable, Hashable, Identifiable {
        public var name: String
        public var description: String
        public var defaultValue: String?
        public var isRequired: Bool
        public var isSecret: Bool
        public var isRepeated: Bool
        public var choices: [String]
        public var id: String { name }

        public init(name: String, description: String = "", defaultValue: String? = nil, isRequired: Bool = false, isSecret: Bool = false, isRepeated: Bool = false, choices: [String] = []) {
            self.name = name; self.description = description; self.defaultValue = defaultValue
            self.isRequired = isRequired; self.isSecret = isSecret; self.isRepeated = isRepeated; self.choices = choices
        }
    }

    public struct LaunchArgument: Codable, Sendable, Hashable {
        public var type: String
        public var name: String?
        public var value: String?
        public var valueHint: String?
        public var description: String
        public var defaultValue: String?
        public var isRequired: Bool
        public var isRepeated: Bool
        public var variables: [String: LaunchInput]

        public init(type: String = "positional", name: String? = nil, value: String? = nil, valueHint: String? = nil, description: String = "", defaultValue: String? = nil, isRequired: Bool = false, isRepeated: Bool = false, variables: [String: LaunchInput] = [:]) {
            self.type = type; self.name = name; self.value = value; self.valueHint = valueHint
            self.description = description; self.defaultValue = defaultValue; self.isRequired = isRequired
            self.isRepeated = isRepeated; self.variables = variables
        }

        public var inputs: [LaunchInput] {
            if !variables.isEmpty { return variables.values.sorted { $0.name < $1.name } }
            guard value == nil else { return [] }
            let key = valueHint ?? name ?? "argument"
            return [LaunchInput(name: key, description: description, defaultValue: defaultValue, isRequired: isRequired, isRepeated: isRepeated)]
        }

        func rendered(values: [String: String]) throws -> [String] {
            var resolved = value
            for input in variables.values {
                let supplied = values[input.name] ?? input.defaultValue
                if input.isRequired && (supplied?.isEmpty != false) { throw ToolInputError("\(input.name) is required to start this connector.") }
                if let supplied, !input.choices.isEmpty, !input.choices.contains(supplied) { throw ToolInputError("\(input.name) must use a declared choice.") }
                resolved = resolved?.replacingOccurrences(of: "{\(input.name)}", with: supplied ?? "")
            }
            if variables.isEmpty, value == nil, let input = inputs.first {
                let supplied = values[input.name] ?? input.defaultValue
                if input.isRequired && (supplied?.isEmpty != false) { throw ToolInputError("\(input.name) is required to start this connector.") }
                if let supplied, !input.choices.isEmpty, !input.choices.contains(supplied) { throw ToolInputError("\(input.name) must use a declared choice.") }
                resolved = supplied
            }
            guard let resolved, !resolved.isEmpty else { return [] }
            let repetitions = isRepeated ? resolved.split(separator: "\n").map(String.init) : [resolved]
            return repetitions.flatMap { item in type == "named" ? [name ?? "", item].filter { !$0.isEmpty } : [item] }
        }
    }

    public struct Package: Codable, Sendable, Hashable {
        public var registryType: String
        public var identifier: String
        public var version: String?
        public var runtimeHint: String?
        public var transportType: String
        public var runtimeArguments: [LaunchArgument]
        public var packageArguments: [LaunchArgument]
        public var environmentVariables: [LaunchInput]

        public init(registryType: String, identifier: String, version: String? = nil, runtimeHint: String? = nil, transportType: String = "stdio", runtimeArguments: [LaunchArgument] = [], packageArguments: [LaunchArgument] = [], environmentVariables: [LaunchInput] = []) {
            self.registryType = registryType; self.identifier = identifier; self.version = version; self.runtimeHint = runtimeHint
            self.transportType = transportType; self.runtimeArguments = runtimeArguments; self.packageArguments = packageArguments
            self.environmentVariables = environmentVariables
        }

        public var isAutonomousCompatible: Bool {
            transportType == "stdio" && ["npm", "pypi"].contains(registryType.lowercased())
                && (runtimeHint == nil || ["npx", "uvx"].contains(runtimeHint!.lowercased()))
        }
        public var launchInputs: [LaunchInput] {
            let arguments = (runtimeArguments + packageArguments).flatMap(\.inputs)
            return Dictionary((environmentVariables + arguments).map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first }).values.sorted { $0.name < $1.name }
        }

        enum CodingKeys: String, CodingKey { case registryType, identifier, version, runtimeHint, transportType, runtimeArguments, packageArguments, environmentVariables }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            registryType = try c.decode(String.self, forKey: .registryType); identifier = try c.decode(String.self, forKey: .identifier)
            version = try c.decodeIfPresent(String.self, forKey: .version); runtimeHint = try c.decodeIfPresent(String.self, forKey: .runtimeHint)
            transportType = try c.decodeIfPresent(String.self, forKey: .transportType) ?? "stdio"
            runtimeArguments = try c.decodeIfPresent([LaunchArgument].self, forKey: .runtimeArguments) ?? []
            packageArguments = try c.decodeIfPresent([LaunchArgument].self, forKey: .packageArguments) ?? []
            environmentVariables = try c.decodeIfPresent([LaunchInput].self, forKey: .environmentVariables) ?? []
        }
    }

    public var id: String { name }
    public var name: String
    public var displayName: String
    public var description: String
    public var version: String
    public var repositoryURL: URL?
    public var remotes: [Remote]
    public var packages: [Package]
    public var publishedAt: Date?

    public var supportsPhone: Bool { remotes.contains { $0.type == "streamable-http" && $0.url.scheme == "https" } }
    public var supportsAutonomous: Bool { packages.contains(where: \.isAutonomousCompatible) }
    public var preferredRemote: Remote? { remotes.first { $0.type == "streamable-http" && $0.url.scheme == "https" } }

    public init(name: String, displayName: String? = nil, description: String = "", version: String = "", repositoryURL: URL? = nil, remotes: [Remote] = [], packages: [Package] = [], publishedAt: Date? = nil) {
        self.name = name
        self.displayName = displayName ?? Self.friendlyName(name)
        self.description = description
        self.version = version
        self.repositoryURL = repositoryURL
        self.remotes = remotes
        self.packages = packages
        self.publishedAt = publishedAt
    }

    static func friendlyName(_ name: String) -> String {
        let tail = name.split(separator: "/").last.map(String.init) ?? name
        return tail.replacingOccurrences(of: "-mcp-server", with: "").replacingOccurrences(of: "mcp-server-", with: "").replacingOccurrences(of: "-mcp", with: "").replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ").split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    init?(registryValue item: JSONValue) {
        guard let server = item["server"], let name = server["name"]?.stringValue else { return nil }
        let official = item["_meta"]?["io.modelcontextprotocol.registry/official"]
        guard official?["status"]?.stringValue ?? "active" == "active", official?["isLatest"]?.boolValue ?? true else { return nil }
        let remotes = (server["remotes"]?.arrayValue ?? []).compactMap { value -> Remote? in
            guard let type = value["type"]?.stringValue, let text = value["url"]?.stringValue, let url = URL(string: text) else { return nil }
            return Remote(type: type, url: url)
        }
        func launchInput(_ value: JSONValue, fallbackName: String? = nil) -> LaunchInput? {
            guard let name = value["name"]?.stringValue ?? fallbackName else { return nil }
            return LaunchInput(
                name: name,
                description: value["description"]?.stringValue ?? "",
                defaultValue: value["default"]?.stringValue,
                isRequired: value["isRequired"]?.boolValue ?? false,
                isSecret: value["isSecret"]?.boolValue ?? false,
                isRepeated: value["isRepeated"]?.boolValue ?? false,
                choices: value["choices"]?.arrayValue?.compactMap(\.stringValue) ?? []
            )
        }
        func launchArgument(_ value: JSONValue) -> LaunchArgument? {
            guard let type = value["type"]?.stringValue else { return nil }
            var variables: [String: LaunchInput] = [:]
            for (key, item) in value["variables"]?.objectValue ?? [:] {
                variables[key] = launchInput(item, fallbackName: key)
            }
            return LaunchArgument(
                type: type, name: value["name"]?.stringValue, value: value["value"]?.stringValue,
                valueHint: value["valueHint"]?.stringValue, description: value["description"]?.stringValue ?? "",
                defaultValue: value["default"]?.stringValue, isRequired: value["isRequired"]?.boolValue ?? false,
                isRepeated: value["isRepeated"]?.boolValue ?? false, variables: variables
            )
        }
        let packages = (server["packages"]?.arrayValue ?? []).compactMap { value -> Package? in
            guard let type = value["registryType"]?.stringValue ?? value["registry_type"]?.stringValue,
                  let identifier = value["identifier"]?.stringValue else { return nil }
            return Package(
                registryType: type, identifier: identifier, version: value["version"]?.stringValue,
                runtimeHint: value["runtimeHint"]?.stringValue ?? value["runtime_hint"]?.stringValue,
                transportType: value["transport"]?["type"]?.stringValue ?? "",
                runtimeArguments: (value["runtimeArguments"]?.arrayValue ?? []).compactMap(launchArgument),
                packageArguments: (value["packageArguments"]?.arrayValue ?? []).compactMap(launchArgument),
                environmentVariables: (value["environmentVariables"]?.arrayValue ?? []).compactMap { launchInput($0) }
            )
        }
        let date = official?["publishedAt"]?.stringValue.flatMap { ISO8601DateFormatter().date(from: $0) }
        self.init(
            name: name,
            displayName: server["title"]?.stringValue,
            description: server["description"]?.stringValue ?? "",
            version: server["version"]?.stringValue ?? "",
            repositoryURL: server["repository"]?["url"]?.stringValue.flatMap(URL.init(string:)),
            remotes: remotes,
            packages: packages,
            publishedAt: date
        )
    }
}

public struct RegistryPage: Sendable, Hashable {
    public var servers: [RegistryServer]
    public var nextCursor: String?
    public var count: Int
}

/// Search and cursor pagination for Registry v0.1. Results are never copied into the app bundle.
public struct MCPRegistryClient: Sendable {
    public static let baseURL = URL(string: "https://registry.modelcontextprotocol.io/v0.1/servers")!
    private let transport: any HTTPTransport
    public init(transport: any HTTPTransport) { self.transport = transport }

    public func page(search: String? = nil, cursor: String? = nil, limit: Int = 100) async throws -> RegistryPage {
        var parts = URLComponents(url: Self.baseURL, resolvingAgainstBaseURL: false)!
        var query = [URLQueryItem(name: "version", value: "latest"), URLQueryItem(name: "limit", value: String(min(max(limit, 1), 100)))]
        if let search = search?.trimmingCharacters(in: .whitespacesAndNewlines), !search.isEmpty { query.append(URLQueryItem(name: "search", value: search)) }
        if let cursor, !cursor.isEmpty { query.append(URLQueryItem(name: "cursor", value: cursor)) }
        parts.queryItems = query
        let response = try await transport.send(HTTPRequest(url: parts.url!, headers: ["Accept": "application/json"], idleTimeout: 30))
        guard response.isSuccess else { throw HTTPError.status(code: response.status, body: response.text, headers: response.headers) }
        guard let root = JSONValue.parse(response.body), let values = root["servers"]?.arrayValue else {
            throw HTTPError.undecodable(status: response.status, type: "MCP Registry page", detail: "missing servers", body: response.text)
        }
        let servers = values.compactMap(RegistryServer.init(registryValue:)).sorted(by: Self.catalogOrder)
        return RegistryPage(servers: servers, nextCursor: root["metadata"]?["nextCursor"]?.stringValue, count: root["metadata"]?["count"]?.intValue ?? servers.count)
    }

    /// Fetches every matching latest active entry, following the Registry's opaque cursor.
    public func all(search: String? = nil, maximumPages: Int = 1_000) async throws -> [RegistryServer] {
        var result: [RegistryServer] = []
        var cursor: String?
        var seen = Set<String>()
        for _ in 0..<maximumPages {
            let page = try await page(search: search, cursor: cursor)
            for server in page.servers where seen.insert(server.name).inserted { result.append(server) }
            guard let next = page.nextCursor, next != cursor else { break }
            cursor = next
        }
        return result.sorted(by: Self.catalogOrder)
    }

    public static func catalogOrder(_ lhs: RegistryServer, _ rhs: RegistryServer) -> Bool {
        let left = wellKnownRank(lhs), right = wellKnownRank(rhs)
        if left != right { return left < right }
        return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
    }

    private static let wellKnown = ["github", "slack", "notion", "linear", "figma", "google drive", "google docs", "google sheets", "google slides", "gmail", "google calendar", "dropbox", "atlassian", "stripe", "sentry"]
    private static func wellKnownRank(_ server: RegistryServer) -> Int {
        let value = "\(server.name) \(server.displayName)".lowercased()
        return wellKnown.firstIndex(where: value.contains) ?? Int.max
    }
}
