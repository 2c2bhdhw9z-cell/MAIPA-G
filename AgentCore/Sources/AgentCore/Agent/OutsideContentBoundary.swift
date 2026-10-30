import Foundation

// Stability 42: tool, web and connector text is data, never orders. The agent loop enforces it in
// code: once any of the tools below (or OpenRouter's own web tools) has put outside text in the
// conversation, actions with effects beyond MAIPA-G pause for the person's typed approval, decided
// by the call itself and never by how anything is worded.

extension WebSearchTool { public var bringsOutsideContent: Bool { true } }
extension ReadWebPageTool { public var bringsOutsideContent: Bool { true } }
extension ReadFileTool { public var bringsOutsideContent: Bool { true } }
extension SearchCodeTool { public var bringsOutsideContent: Bool { true } }
extension ReadRepoFileTool { public var bringsOutsideContent: Bool { true } }
extension ReadOtherRepositoryFileTool { public var bringsOutsideContent: Bool { true } }

enum OutsideContentBoundary {
    static func connectorApproval(_ definition: ConnectorToolDefinition, arguments: JSONValue) -> ToolApprovalRequest? {
        let words = ConnectorActionPolicy.words(definition.originalName)
        let action = "\(String(definition.serverName.prefix(60))) · \(String(definition.title.prefix(80)))"
        if words.contains(where: ConnectorActionPolicy.commandWords.contains), words.first.map(ConnectorActionPolicy.readWords.contains) != true {
            let command = ConnectorActionPolicy.commandText(arguments)
            guard ShellRisk.reachesNetwork(command) else { return nil }
            return ToolApprovalRequest(question: "This chat now contains text from the web, a repo or a connector. Allow \(action) to run a command that reaches the network?\n\(String(command.prefix(500)))", allowLabel: "Run command")
        }
        // Reading stays free; anything else a connector does could act on someone else's words.
        if let first = words.first, ConnectorActionPolicy.readWords.contains(first), definition.destructiveHint != true { return nil }
        if definition.readOnlyHint == true, definition.destructiveHint != true, !words.contains(where: { ConnectorActionPolicy.spendingWords.contains($0) || ConnectorActionPolicy.deletingWords.contains($0) || ConnectorActionPolicy.accessWords.contains($0) }) { return nil }
        return ToolApprovalRequest(question: "This chat now contains text from the web, a repo or a connector. Allow \(action)? It acts outside MAIPA-G.", allowLabel: "Allow")
    }
}

extension MCPTool {
    public var bringsOutsideContent: Bool { true }
    public func approvalAfterOutsideContent(for arguments: JSONValue) async -> ToolApprovalRequest? {
        OutsideContentBoundary.connectorApproval(definition, arguments: arguments)
    }
}

#if os(Linux)
extension AutonomousMCPTool {
    public var bringsOutsideContent: Bool { true }
    public func approvalAfterOutsideContent(for arguments: JSONValue) async -> ToolApprovalRequest? {
        OutsideContentBoundary.connectorApproval(definition, arguments: arguments)
    }
}
#endif

extension StdioMCPTool {
    public var bringsOutsideContent: Bool { true }
    public func approvalAfterOutsideContent(for arguments: JSONValue) async -> ToolApprovalRequest? {
        guard arguments["method"]?.stringValue == "tools/call" else { return nil }
        let toolName = arguments["params"]?["name"]?.stringValue ?? "unnamed"
        let definition = ConnectorToolDefinition(serverID: name, serverName: name, originalName: toolName)
        return OutsideContentBoundary.connectorApproval(definition, arguments: arguments["params"]?["arguments"] ?? .object([:]))
    }
}

extension HookedTool {
    public var bringsOutsideContent: Bool { inner.bringsOutsideContent }
    public func approvalAfterOutsideContent(for arguments: JSONValue) async -> ToolApprovalRequest? {
        await inner.approvalAfterOutsideContent(for: arguments)
    }
}

extension ShellRisk {
    static let networkPrograms: Set<String> = ["curl", "wget", "nc", "ncat", "netcat", "socat", "telnet", "ssh", "scp", "sftp", "ftp", "rsync", "http", "https", "aria2c", "lynx", "w3m"]

    /// Commands that can send data off the machine. Package installs from their registries
    /// (npm, pip, cargo, swift) are left alone; explicit network clients and pushes are not.
    public static func reachesNetwork(_ command: String) -> Bool {
        let value = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return true }
        if ["git push", "git remote add", "git remote set-url", "/dev/tcp/", "/dev/udp/"].contains(where: { value.contains($0) }) { return true }
        for segment in segments(value) {
            let words = segment.split(whereSeparator: \.isWhitespace).map(String.init).filter { !$0.contains("=") || $0.hasPrefix("-") }
            guard let program = words.first.map({ ($0 as NSString).lastPathComponent }) else { continue }
            if networkPrograms.contains(program) { return true }
            // An inline script is split across segments, so the whole command is checked.
            if ["python", "python3", "node", "deno", "bun", "perl", "ruby", "php"].contains(program),
               ["http://", "https://", "socket", "fetch(", "urllib", "requests.", "net/http", "XMLHttpRequest"].contains(where: { value.contains($0) }) { return true }
        }
        return false
    }
}
