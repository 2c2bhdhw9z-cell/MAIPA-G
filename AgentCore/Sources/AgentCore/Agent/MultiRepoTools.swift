import Foundation

/// In a chat with several repos, one tool per job (read_file, edit_file, save_changes…) takes an
/// optional `repo` argument and hands the call to that repo's own tool, with its own staged
/// changes, branch and save rules. Without `repo` the chat's first repo is used, so a chat with a
/// single repo never sees this wrapper at all.
public struct RepoRoutedTool: AgentTool {
    /// Full repo names ("owner/name") to that repo's tool, in the order the chat lists them.
    public let routes: [(repo: String, tool: any AgentTool)]

    public init(routes: [(repo: String, tool: any AgentTool)]) {
        precondition(!routes.isEmpty)
        self.routes = routes
    }

    /// Groups each repo's tools by name and wraps every name that more than one repo offers.
    /// With a single repo the tools come back untouched.
    public static func combine(_ perRepo: [(repo: String, tools: [any AgentTool])]) -> [any AgentTool] {
        guard perRepo.count > 1, let first = perRepo.first else { return perRepo.first?.tools ?? [] }
        return first.tools.map { tool in
            var routes: [(repo: String, tool: any AgentTool)] = [(first.repo, tool)]
            for other in perRepo.dropFirst() {
                if let match = other.tools.first(where: { $0.name == tool.name }) { routes.append((other.repo, match)) }
            }
            return routes.count > 1 ? RepoRoutedTool(routes: routes) : tool
        }
    }

    public var name: String { routes[0].tool.name }

    public var spec: ToolSpec {
        var spec = routes[0].tool.spec
        let names = routes.map(\.repo)
        spec.function.description += " This chat has several repos (\(names.joined(separator: ", "))); pass repo to choose one. Without it, \(names[0]) is used. Each repo keeps its own staged changes and is saved to itself."
        if case .object(var parameters) = spec.function.parameters {
            var properties = parameters["properties"]?.objectValue ?? [:]
            properties["repo"] = ["type": "string", "enum": .array(names.map(JSONValue.string)), "description": "Which repo, as owner/name."]
            parameters["properties"] = .object(properties)
            spec.function.parameters = .object(parameters)
        }
        return spec
    }

    /// The tool for the named repo (case-insensitive, also by its short name when that is
    /// unambiguous) and the arguments without `repo`.
    func route(_ arguments: JSONValue) throws -> (tool: any AgentTool, arguments: JSONValue) {
        guard case .object(var object) = arguments, let wanted = object["repo"]?.stringValue?.trimmingCharacters(in: .whitespaces), !wanted.isEmpty else {
            return (routes[0].tool, Self.withoutRepo(arguments))
        }
        object["repo"] = nil
        if let exact = routes.first(where: { $0.repo.caseInsensitiveCompare(wanted) == .orderedSame }) { return (exact.tool, .object(object)) }
        let short = routes.filter { ($0.repo.split(separator: "/").last.map(String.init) ?? "").caseInsensitiveCompare(wanted) == .orderedSame }
        if short.count == 1 { return (short[0].tool, .object(object)) }
        throw ToolInputError("This chat has no repo named \(wanted). Use one of: \(routes.map(\.repo).joined(separator: ", ")).")
    }

    static func withoutRepo(_ arguments: JSONValue) -> JSONValue {
        guard case .object(var object) = arguments else { return arguments }
        object["repo"] = nil
        return .object(object)
    }

    private func label(_ arguments: JSONValue) -> String? {
        guard let wanted = arguments["repo"]?.stringValue, (try? route(arguments)) != nil else { return nil }
        return wanted
    }

    public func runningSummary(for arguments: JSONValue) -> String {
        guard let routed = try? route(arguments) else { return routes[0].tool.runningSummary(for: arguments) }
        let text = routed.tool.runningSummary(for: routed.arguments)
        return label(arguments).map { "\(text) (\($0))" } ?? text
    }
    public func initialSubagents(for arguments: JSONValue, callID: String) -> [SubagentRunItem]? {
        guard let routed = try? route(arguments) else { return nil }
        return routed.tool.initialSubagents(for: routed.arguments, callID: callID)
    }
    public func alwaysAsks(for arguments: JSONValue) async -> Bool {
        guard let routed = try? route(arguments) else { return false }
        return await routed.tool.alwaysAsks(for: routed.arguments)
    }

    public func approvalRequest(for arguments: JSONValue) async -> ToolApprovalRequest? {
        guard let routed = try? route(arguments) else { return nil }
        guard var request = await routed.tool.approvalRequest(for: routed.arguments) else { return nil }
        if let label = label(arguments) { request.question += " (\(label))" }
        return request
    }
    public func approvalAfterOutsideContent(for arguments: JSONValue) async -> ToolApprovalRequest? {
        guard let routed = try? route(arguments) else { return nil }
        return await routed.tool.approvalAfterOutsideContent(for: routed.arguments)
    }
    public var bringsOutsideContent: Bool { routes.contains { $0.tool.bringsOutsideContent } }

    public func run(arguments: JSONValue, progress: @escaping @Sendable (String) -> Void) async throws -> ToolOutput {
        let routed = try route(arguments)
        return try await routed.tool.run(arguments: routed.arguments, progress: progress)
    }
    public func runLive(arguments: JSONValue, update: @escaping @Sendable (ToolLiveUpdate) -> Void) async throws -> ToolOutput {
        let routed = try route(arguments)
        return try await routed.tool.runLive(arguments: routed.arguments, update: update)
    }
    public func runLive(arguments: JSONValue, callID: String, existingSubagents: [SubagentRunItem]?, update: @escaping @Sendable (ToolLiveUpdate) -> Void) async throws -> ToolOutput {
        let routed = try route(arguments)
        return try await routed.tool.runLive(arguments: routed.arguments, callID: callID, existingSubagents: existingSubagents, update: update)
    }
    public func runApproved(arguments: JSONValue, progress: @escaping @Sendable (String) -> Void) async throws -> ToolOutput {
        let routed = try route(arguments)
        return try await routed.tool.runApproved(arguments: routed.arguments, progress: progress)
    }
    public func runApprovedLive(arguments: JSONValue, update: @escaping @Sendable (ToolLiveUpdate) -> Void) async throws -> ToolOutput {
        let routed = try route(arguments)
        return try await routed.tool.runApprovedLive(arguments: routed.arguments, update: update)
    }
    public func runApprovedLive(arguments: JSONValue, callID: String, existingSubagents: [SubagentRunItem]?, update: @escaping @Sendable (ToolLiveUpdate) -> Void) async throws -> ToolOutput {
        let routed = try route(arguments)
        return try await routed.tool.runApprovedLive(arguments: routed.arguments, callID: callID, existingSubagents: existingSubagents, update: update)
    }
}
