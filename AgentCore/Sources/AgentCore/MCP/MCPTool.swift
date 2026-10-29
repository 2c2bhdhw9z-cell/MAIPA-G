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
        return ToolOutput(
            forModel: response.text,
            summary: "Used \(definition.serverName) · \(definition.title)",
            detail: response.text,
            isError: response.isError
        )
    }
}
