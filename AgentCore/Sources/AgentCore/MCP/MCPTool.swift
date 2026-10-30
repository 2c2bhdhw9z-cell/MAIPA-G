import Foundation

/// Adapts one discovered MCP tool to the same agent-tool path as repo and web activity.
public struct MCPTool: AgentTool {
    public let definition: ConnectorToolDefinition
    public let session: MCPConnectorSession
    public var name: String { definition.namespacedName }

    public init(definition: ConnectorToolDefinition, session: MCPConnectorSession) {
        self.definition = definition; self.session = session
    }

    public var spec: ToolSpec {
        ToolSpec(name: name, description: "\(definition.serverName): \(definition.description)", parameters: definition.inputSchema)
    }

    public func runningSummary(for arguments: JSONValue) -> String { "Using \(definition.serverName) · \(definition.title)…" }

    public func run(arguments: JSONValue, progress: @escaping @Sendable (String) -> Void) async throws -> ToolOutput {
        progress("Waiting for \(definition.serverName)…")
        let response = try await session.call(tool: definition.originalName, arguments: arguments)
        let text = ConnectorOutputLimit.cap(response.text)
        return ToolOutput(
            forModel: text,
            summary: "Used \(definition.serverName) · \(definition.title)",
            detail: text,
            isError: response.isError
        )
    }
}


enum ConnectorOutputLimit {
    static let characters = 80_000

    static func cap(_ text: String) -> String {
        guard text.count > characters else { return text }
        let half = characters / 2
        return String(text.prefix(half)) + "\n[Connector output cut: \(text.count - characters) characters omitted]\n" + String(text.suffix(half))
    }
}
