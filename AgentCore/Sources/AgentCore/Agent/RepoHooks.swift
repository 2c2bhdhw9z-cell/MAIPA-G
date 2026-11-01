import Foundation

/// Actions that run on events, read from the chat's repo in Kiro's two hook formats:
///
/// - `.kiro/hooks/<id>.json`: `{"version":"v1","hooks":[{"name","trigger","matcher","action":{"type":"command"|"agent","command"|"prompt"}}]}`
/// - `.kiro/hooks/<id>.kiro.hook`: `{"enabled":true,"name","when":{"type":"fileEdited","patterns":[…]},"then":{"type":"askAgent"|"runCommand","prompt"|"command"}}`
///
/// MAIPA-G's events: a file staged (`PostFileSave`, `PostFileCreate`, `PostFileDelete`), any
/// tool finishing (`PostToolUse`, matched against the tool name) and changes saved to GitHub
/// (`PostSave`). Commands run on the chat computer through MAIPA-G's own code after the staged
/// files are put there; agent hooks add their prompt to what the AI reads next.
public struct RepoHook: Sendable, Hashable {
    public enum Event: String, Sendable, Hashable, CaseIterable {
        case fileSaved = "PostFileSave", fileCreated = "PostFileCreate", fileDeleted = "PostFileDelete"
        case toolUsed = "PostToolUse", changesSaved = "PostSave"
    }

    public enum Action: Sendable, Hashable {
        case command(String)
        case agent(String)
    }

    public var name: String
    public var source: String
    public var event: Event
    /// A regular expression on the tool name (PostToolUse) or file path (file events).
    public var matcher: String?
    /// Globs on the file path, from the .kiro.hook format.
    public var patterns: [String]
    public var action: Action

    public init(name: String, source: String, event: Event, matcher: String? = nil, patterns: [String] = [], action: Action) {
        self.name = name
        self.source = source
        self.event = event
        self.matcher = matcher
        self.patterns = patterns
        self.action = action
    }

    func matches(event: Event, tool: String, path: String?) -> Bool {
        guard self.event == event else { return false }
        if let matcher, !matcher.isEmpty {
            let subject = event == .toolUsed || event == .changesSaved ? tool : (path ?? "")
            guard subject.range(of: matcher, options: .regularExpression) != nil else { return false }
        }
        if !patterns.isEmpty {
            guard let path, patterns.contains(where: { Glob($0).matches(path) }) else { return false }
        }
        return true
    }
}

public enum RepoHooks {
    public static let folder = ".kiro/hooks/"

    public static func isHookFile(_ path: String) -> Bool {
        path.hasPrefix(folder) && (path.hasSuffix(".json") || path.hasSuffix(".kiro.hook")) && !path.dropFirst(folder.count).contains("/")
    }

    /// Reads every hook file; a file that can't be read is reported, never guessed at.
    public static func parse(path: String, text: String) -> (hooks: [RepoHook], problem: String?) {
        guard let value = JSONValue.parse(Data(text.utf8)) else { return ([], "\(path) isn't valid JSON.") }
        var hooks: [RepoHook] = []
        if let list = value["hooks"]?.arrayValue {
            for (index, item) in list.enumerated() {
                let name = item["name"]?.stringValue ?? "\(path) #\(index + 1)"
                guard let trigger = item["trigger"]?.stringValue, let event = RepoHook.Event(rawValue: trigger) else { continue }
                let actionValue = item["action"]
                let action: RepoHook.Action
                switch actionValue?["type"]?.stringValue {
                case "command":
                    guard let command = actionValue?["command"]?.stringValue, !command.isEmpty else { continue }
                    action = .command(command)
                case "agent":
                    guard let prompt = actionValue?["prompt"]?.stringValue, !prompt.isEmpty else { continue }
                    action = .agent(prompt)
                default: continue
                }
                hooks.append(RepoHook(name: name, source: path, event: event, matcher: item["matcher"]?.stringValue, action: action))
            }
            return (hooks, nil)
        }
        if value["when"] != nil {
            if value["enabled"]?.boolValue == false { return ([], nil) }
            let name = value["name"]?.stringValue ?? path
            let event: RepoHook.Event
            switch value["when"]?["type"]?.stringValue {
            case "fileEdited": event = .fileSaved
            case "fileCreated": event = .fileCreated
            case "fileDeleted": event = .fileDeleted
            case "postToolUse": event = .toolUsed
            default: return ([], nil)
            }
            let patterns = (value["when"]?["patterns"]?.arrayValue ?? []).compactMap(\.stringValue)
            let action: RepoHook.Action
            switch value["then"]?["type"]?.stringValue {
            case "askAgent":
                guard let prompt = value["then"]?["prompt"]?.stringValue, !prompt.isEmpty else { return ([], "\(path) has no prompt.") }
                action = .agent(prompt)
            case "runCommand":
                guard let command = value["then"]?["command"]?.stringValue, !command.isEmpty else { return ([], "\(path) has no command.") }
                action = .command(command)
            default: return ([], nil)
            }
            return ([RepoHook(name: name, source: path, event: event, matcher: value["when"]?["toolTypes"]?.arrayValue?.compactMap(\.stringValue).joined(separator: "|"), patterns: patterns, action: action)], nil)
        }
        return ([], "\(path) isn't a hook file MAIPA-G knows.")
    }

    public static func load(from workspace: RepoWorkspace) async -> (hooks: [RepoHook], problems: [String]) {
        guard let tree = try? await workspace.tree() else { return ([], []) }
        var hooks: [RepoHook] = []
        var problems: [String] = []
        for entry in tree.entries where entry.isFile && isHookFile(entry.path) {
            guard case .text(let text, _) = try? await workspace.readFile(entry.path) else {
                problems.append("\(entry.path) couldn't be read.")
                continue
            }
            let parsed = parse(path: entry.path, text: text)
            hooks += parsed.hooks
            if let problem = parsed.problem { problems.append(problem) }
        }
        return (Array(hooks.prefix(20)), problems)
    }

    static func event(forTool name: String) -> RepoHook.Event? {
        switch name {
        case "edit_file", "append_file": .fileSaved
        case "create_file": .fileCreated
        case "delete_file": .fileDeleted
        case "save_changes": .changesSaved
        default: nil
        }
    }
}

/// Wraps a tool so the repo's hooks run after it succeeds. The hook results are added to what
/// the AI reads, so it sees (for example) the test results right after saving.
public struct HookedTool: AgentTool {
    public typealias CommandRunner = @Sendable (_ command: String) async throws -> String

    let inner: any AgentTool
    let hooks: [RepoHook]
    let runCommand: CommandRunner?

    public init(_ inner: any AgentTool, hooks: [RepoHook], runCommand: CommandRunner?) {
        self.inner = inner
        self.hooks = hooks
        self.runCommand = runCommand
    }

    /// Wraps only the tools some hook listens to.
    public static func wrap(_ tools: [any AgentTool], hooks: [RepoHook], runCommand: CommandRunner?) -> [any AgentTool] {
        guard !hooks.isEmpty else { return tools }
        return tools.map { tool in
            let events = Set([RepoHooks.event(forTool: tool.name), .toolUsed].compactMap { $0 })
            return hooks.contains(where: { events.contains($0.event) }) ? HookedTool(tool, hooks: hooks, runCommand: runCommand) : tool
        }
    }

    public var name: String { inner.name }
    public var spec: ToolSpec { inner.spec }
    public func runningSummary(for arguments: JSONValue) -> String { inner.runningSummary(for: arguments) }
    public func initialSubagents(for arguments: JSONValue, callID: String) -> [SubagentRunItem]? {
        inner.initialSubagents(for: arguments, callID: callID)
    }
    public func approvalRequest(for arguments: JSONValue) async -> ToolApprovalRequest? { await inner.approvalRequest(for: arguments) }

    public func run(arguments: JSONValue, progress: @escaping @Sendable (String) -> Void) async throws -> ToolOutput {
        try await afterwards(try await inner.run(arguments: arguments, progress: progress), arguments: arguments, progress: progress)
    }

    public func runLive(arguments: JSONValue, update: @escaping @Sendable (ToolLiveUpdate) -> Void) async throws -> ToolOutput {
        let output = try await inner.runLive(arguments: arguments, update: update)
        return try await afterwards(output, arguments: arguments) { msg in
            update(ToolLiveUpdate(summary: msg, detail: output.detail, subagents: output.subagents))
        }
    }

    public func runLive(arguments: JSONValue, callID: String, existingSubagents: [SubagentRunItem]?, update: @escaping @Sendable (ToolLiveUpdate) -> Void) async throws -> ToolOutput {
        let output = try await inner.runLive(arguments: arguments, callID: callID, existingSubagents: existingSubagents, update: update)
        return try await afterwards(output, arguments: arguments) { msg in
            update(ToolLiveUpdate(summary: msg, detail: output.detail, subagents: output.subagents))
        }
    }

    public func runApproved(arguments: JSONValue, progress: @escaping @Sendable (String) -> Void) async throws -> ToolOutput {
        try await afterwards(try await inner.runApproved(arguments: arguments, progress: progress), arguments: arguments, progress: progress)
    }

    public func runApprovedLive(arguments: JSONValue, update: @escaping @Sendable (ToolLiveUpdate) -> Void) async throws -> ToolOutput {
        let output = try await inner.runApprovedLive(arguments: arguments, update: update)
        return try await afterwards(output, arguments: arguments) { msg in
            update(ToolLiveUpdate(summary: msg, detail: output.detail, subagents: output.subagents))
        }
    }

    public func runApprovedLive(arguments: JSONValue, callID: String, existingSubagents: [SubagentRunItem]?, update: @escaping @Sendable (ToolLiveUpdate) -> Void) async throws -> ToolOutput {
        let output = try await inner.runApprovedLive(arguments: arguments, callID: callID, existingSubagents: existingSubagents, update: update)
        return try await afterwards(output, arguments: arguments) { msg in
            update(ToolLiveUpdate(summary: msg, detail: output.detail, subagents: output.subagents))
        }
    }

    func afterwards(_ output: ToolOutput, arguments: JSONValue, progress: @escaping @Sendable (String) -> Void) async throws -> ToolOutput {
        guard !output.isError else { return output }
        let path = arguments["path"]?.stringValue
        var matching = hooks.filter { $0.matches(event: .toolUsed, tool: name, path: path) }
        if let event = RepoHooks.event(forTool: name) {
            matching += hooks.filter { $0.matches(event: event, tool: name, path: path) }
        }
        guard !matching.isEmpty else { return output }
        var reports: [String] = []
        for hook in matching {
            switch hook.action {
            case .agent(let prompt):
                reports.append("Hook “\(hook.name)” (\(hook.source)) asks: \(String(prompt.prefix(4_000)))")
            case .command(let command):
                guard let runCommand else {
                    reports.append("Hook “\(hook.name)” wanted to run `\(String(command.prefix(300)))`, but this chat has no computer to run it on.")
                    continue
                }
                if ShellRisk.isRisky(command) {
                    reports.append("Hook “\(hook.name)” wasn't run automatically because `\(String(command.prefix(300)))` can delete files or reach other services. Run it with the computer's command tool, which asks the person first.")
                    continue
                }
                progress("Running hook \(hook.name)…")
                do {
                    let result = try await runCommand(command)
                    reports.append("Hook “\(hook.name)” ran `\(String(command.prefix(300)))`:\n\(Self.headAndTail(result))")
                } catch {
                    reports.append("Hook “\(hook.name)” ran `\(String(command.prefix(300)))` and it failed: \(Self.headAndTail(ErrorExplainer.explain(error).message))")
                }
            }
        }
        var updated = output
        let text = reports.joined(separator: "\n\n")
        updated.forModel += "\n\n" + text
        updated.detail = (updated.detail.map { $0 + "\n\n" } ?? "") + text
        return updated
    }

    static func headAndTail(_ text: String, limit: Int = 6_000) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit / 2)) + "\n[… \(text.count - limit) characters cut …]\n" + String(text.suffix(limit / 2))
    }
}

/// A hook file that couldn't be used, for the diagnostics log.
public struct RepoHookProblem: Error, Sendable, CustomStringConvertible {
    public var message: String
    public init(message: String) { self.message = message }
    public var description: String { message }
}
