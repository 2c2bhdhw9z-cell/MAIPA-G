import Foundation

/// Trusted, app-driven use of a chat computer reached through a connector such as Sprites. The
/// app itself (not the model) uses this to check the machine, recreate it when it is missing,
/// put the phone's staged changes onto it and take checkpoints. Tools are found by their names
/// and input schemas, so any computer service with similar tools works.
public struct ComputerControl: Sendable {
    public typealias Call = @Sendable (_ tool: String, _ arguments: JSONValue) async throws -> (text: String, isError: Bool)

    public let tools: [ConnectorToolDefinition]
    public let machine: String
    private let call: Call

    public init(tools: [ConnectorToolDefinition], machine: String, call: @escaping Call) {
        self.tools = tools
        self.machine = machine
        self.call = call
    }

    public enum Failure: Error, Sendable, CustomStringConvertible, Equatable {
        case noCommandTool, noCreateTool, noCheckpointTool, commandFailed(String), machineUnavailable(String)

        public var description: String {
            switch self {
            case .noCommandTool: "This computer service has no command tool MAIPA-G can use."
            case .noCreateTool: "This computer service has no tool for creating a machine."
            case .noCheckpointTool: "This computer service has no checkpoint tool."
            case .commandFailed(let detail): "The computer ran the command but reported a failure: \(detail.prefix(400))"
            case .machineUnavailable(let detail): "The machine isn't available: \(detail.prefix(400))"
            }
        }
    }

    // MARK: Finding tools

    static func words(_ name: String) -> [String] { ConnectorActionPolicy.words(name) }

    func tool(where predicate: ([String]) -> Bool) -> ConnectorToolDefinition? {
        tools.first { predicate(Self.words($0.originalName)) }
    }

    public var commandTool: ConnectorToolDefinition? {
        tool { words in
            let first = words.first ?? ""
            return !["list", "get", "kill", "stop"].contains(first) && words.contains(where: { ["exec", "execute", "run", "command", "shell", "bash"].contains($0) }) && !words.contains("session") && !words.contains("sessions")
        }
    }

    public var listTool: ConnectorToolDefinition? {
        tool { $0.first == "list" && $0.contains(where: { ["sprite", "sprites", "machine", "machines", "vm", "vms", "computers"].contains($0) }) }
    }

    public var createTool: ConnectorToolDefinition? {
        tool { $0.first == "create" && $0.contains(where: { ["sprite", "machine", "vm", "computer"].contains($0) }) }
    }

    public var checkpointTool: ConnectorToolDefinition? {
        tool { $0.contains("create") && $0.contains(where: { ["checkpoint", "snapshot"].contains($0) }) }
    }

    // MARK: Building arguments from schemas

    static func properties(_ schema: JSONValue) -> [String: JSONValue] {
        schema["properties"]?.objectValue ?? [:]
    }

    /// The property that names the machine, such as `sprite`, `name` or `machine`.
    static func machineKey(_ schema: JSONValue) -> String? {
        let keys = properties(schema).keys.sorted()
        for preferred in ["sprite", "sprite_name", "spriteName", "machine", "machine_name", "name", "vm", "id"] where keys.contains(preferred) {
            return preferred
        }
        return keys.first { $0.lowercased().contains("sprite") || $0.lowercased().contains("machine") }
    }

    static func commandKey(_ schema: JSONValue) -> String? {
        let keys = properties(schema).keys.sorted()
        for preferred in ["command", "cmd", "script", "args", "argv"] where keys.contains(preferred) { return preferred }
        return keys.first { $0.lowercased().contains("command") || $0.lowercased().contains("cmd") }
    }

    public func commandArguments(_ command: String, tool: ConnectorToolDefinition) -> JSONValue {
        var arguments: [String: JSONValue] = [:]
        if let key = Self.machineKey(tool.inputSchema) { arguments[key] = .string(machine) }
        let key = Self.commandKey(tool.inputSchema) ?? "command"
        if Self.properties(tool.inputSchema)[key]?["type"]?.stringValue == "array" {
            arguments[key] = .array(["bash", "-lc", .string(command)])
        } else {
            arguments[key] = .string(command)
        }
        return .object(arguments)
    }

    // MARK: Operations

    /// Runs one command chosen by the app's own code, never by the model.
    public func run(_ command: String) async throws -> String {
        guard let tool = commandTool else { throw Failure.noCommandTool }
        let result = try await call(tool.originalName, commandArguments(command, tool: tool))
        if result.isError { throw Failure.commandFailed(result.text) }
        return result.text
    }

    /// The health check's real command: it proves the machine starts and runs a shell, and says
    /// whether MAIPA-G's verified tool setup has finished there.
    public static let healthCommand = "echo maipa-g-health-ok && uname -sm && if [ -f \"$HOME/.maipa-g/ready\" ]; then echo maipa-g-tools-ready; else echo maipa-g-tools-missing; fi"

    /// Starts MAIPA-G's tool setup in the background: the script comes from the app's exact
    /// reviewed commit and runs only if its SHA-256 matches the copy compiled into the app.
    public func startVerifiedSetup(revision: String) async throws -> String {
        guard let url = SystemPrompt.computerSetupURL(revision: revision) else {
            throw Failure.commandFailed("This build has no reviewed commit to take the setup script from.")
        }
        let sha = SystemPrompt.computerSetupSHA256
        let script = """
        set -euo pipefail
        mkdir -p "$HOME/.maipa-g"
        curl --proto '=https' --tlsv1.2 -fsSL --retry 3 -o "$HOME/.maipa-g/setup.sh" '\(url)'
        echo '\(sha)  '"$HOME/.maipa-g/setup.sh" | sha256sum -c - >/dev/null
        nohup bash "$HOME/.maipa-g/setup.sh" > "$HOME/.maipa-g/setup-run.log" 2>&1 < /dev/null &
        echo maipa-g-setup-started
        """
        let output = try await run(script)
        guard output.contains("maipa-g-setup-started") else { throw Failure.commandFailed(output) }
        return "MAIPA-G started its verified tool setup on \(machine). Progress is in ~/.maipa-g/setup-run.log; ~/.maipa-g/ready appears when it finishes."
    }

    public func healthCheck() async throws -> String {
        let output = try await run(Self.healthCommand)
        guard output.contains("maipa-g-health-ok") else { throw Failure.commandFailed(output) }
        return output
    }

    /// Whether the named machine exists, when the service can list machines. Nil means unknown.
    public func machineExists() async throws -> Bool? {
        guard let list = listTool else { return nil }
        let result = try await call(list.originalName, [:])
        if result.isError { throw Failure.machineUnavailable(result.text) }
        let text = result.text
        if let parsed = JSONValue.parse(Data(text.utf8)) {
            return Self.names(in: parsed).contains(machine)
        }
        return text.range(of: #"(^|[^A-Za-z0-9_-])"# + NSRegularExpression.escapedPattern(for: machine) + #"($|[^A-Za-z0-9_-])"#, options: .regularExpression) != nil
    }

    static func names(in value: JSONValue) -> Set<String> {
        var output = Set<String>()
        switch value {
        case .object(let object):
            for (key, child) in object {
                if ["name", "sprite", "id"].contains(key), let text = child.stringValue { output.insert(text) }
                output.formUnion(names(in: child))
            }
        case .array(let items):
            for item in items { output.formUnion(names(in: item)) }
        default: break
        }
        return output
    }

    public func createMachine() async throws {
        guard let create = createTool else { throw Failure.noCreateTool }
        var arguments: [String: JSONValue] = [:]
        arguments[Self.machineKey(create.inputSchema) ?? "name"] = .string(machine)
        let result = try await call(create.originalName, .object(arguments))
        if result.isError { throw Failure.machineUnavailable(result.text) }
    }

    public var destroyTool: ConnectorToolDefinition? {
        tool { ($0.first == "destroy" || $0.first == "delete") && $0.contains(where: { ["sprite", "machine", "vm", "computer"].contains($0) }) }
    }

    /// Recreates a missing or broken machine in code. A missing machine is created again with
    /// the exact configured name. A machine that exists but doesn't answer is only replaced when
    /// the person tapped Replace (`replaceBroken`), because replacing it deletes its files.
    public enum Recovery: Equatable, Sendable { case healthy(String), recreated(String) }

    public func ensureMachine(allowCreate: Bool, replaceBroken: Bool = false) async throws -> Recovery {
        let firstError: Error
        do {
            return .healthy(try await healthCheck())
        } catch Failure.noCommandTool {
            throw Failure.noCommandTool
        } catch {
            firstError = error
        }
        guard allowCreate else { throw firstError }
        let exists = try? await machineExists()
        if exists == true {
            guard replaceBroken, let destroy = destroyTool else {
                throw Failure.machineUnavailable("\(machine) exists but didn't answer a simple command (\(firstError)). Replace it from Settings → Check everything.")
            }
            var arguments: [String: JSONValue] = [:]
            arguments[Self.machineKey(destroy.inputSchema) ?? "name"] = .string(machine)
            let result = try await call(destroy.originalName, .object(arguments))
            if result.isError { throw Failure.machineUnavailable(result.text) }
        }
        try await createMachine()
        return .recreated(try await healthCheck())
    }

    /// Makes the computer's checkout match the phone's staged changes exactly. Trusted code
    /// resets the copy to the chat's commit, then writes every staged file's exact bytes and
    /// removes every staged deletion; the model never retypes anything. `homePath` is relative to
    /// the machine's home folder.
    public func syncStagedChanges(homePath: String, cloneURL: String?, commit: String?, changes: [StagedChange]) async throws -> String {
        guard Self.isSafeRelativePath(homePath) else { throw Failure.commandFailed("Unsafe checkout path \(homePath)") }
        let path = "\"$HOME/\(homePath)\""
        var script = "set -euo pipefail\n"
        if let cloneURL, Self.isPublicCloneURL(cloneURL) {
            script += "if [ ! -d \(path)/.git ]; then mkdir -p \"$(dirname \(path))\" && git clone --quiet '\(cloneURL)' \(path); fi\n"
            script += "git -C \(path) fetch --quiet origin\n"
        }
        script += "cd \(path)\n"
        if let commit, !commit.isEmpty, commit.allSatisfy(\.isHexDigit) {
            script += "git checkout --quiet --detach \(commit)\n"
        }
        script += "git reset --quiet --hard\ngit clean -fdq\n"
        for change in changes {
            switch change {
            case .write(let file, let data, _):
                guard Self.isSafeRelativeRepoPath(file) else { throw Failure.commandFailed("Unsafe staged path \(file)") }
                let quoted = Self.shellQuote(file)
                script += "mkdir -p \"$(dirname \(quoted))\"\nbase64 -d > \(quoted) <<'MAIPA_G_FILE'\n\(data.base64EncodedString(options: [.lineLength76Characters, .endLineWithLineFeed]))\nMAIPA_G_FILE\n"
            case .delete(let file, _):
                guard Self.isSafeRelativeRepoPath(file) else { throw Failure.commandFailed("Unsafe staged path \(file)") }
                script += "rm -f -- \(Self.shellQuote(file))\n"
            }
        }
        script += "git status --short | head -n 200\necho maipa-g-staged-ok\n"
        let output = try await run(script)
        guard output.contains("maipa-g-staged-ok") else { throw Failure.commandFailed(output) }
        return output.replacingOccurrences(of: "maipa-g-staged-ok", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func isSafeRelativeRepoPath(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.hasPrefix("-") && !path.split(separator: "/").contains("..") && !path.contains("\n") && !path.contains("\u{0}") && !path.hasPrefix(".git/") && path != ".git"
    }

    static func isPublicCloneURL(_ url: String) -> Bool {
        url.hasPrefix("https://github.com/") && !url.contains("@") && url.allSatisfy { $0.isLetter || $0.isNumber || ":/._-".contains($0) }
    }

    public func createCheckpoint(comment: String) async throws -> String {
        guard let tool = checkpointTool else { throw Failure.noCheckpointTool }
        var arguments: [String: JSONValue] = [:]
        if let key = Self.machineKey(tool.inputSchema) { arguments[key] = .string(machine) }
        if let key = Self.properties(tool.inputSchema).keys.first(where: { ["comment", "description", "message", "label"].contains($0) }) {
            arguments[key] = .string(String(comment.prefix(200)))
        }
        let result = try await call(tool.originalName, .object(arguments))
        if result.isError { throw Failure.commandFailed(result.text) }
        return result.text
    }

    static func isSafeRelativePath(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.split(separator: "/").contains("..") && path.allSatisfy { $0.isLetter || $0.isNumber || "/._-".contains($0) }
    }

    /// The approximate cost of computer time, from the measured seconds and the configured rate.
    public static func cost(seconds: Double, hourlyRate: Double?) -> Double {
        guard let hourlyRate, hourlyRate > 0, seconds > 0 else { return 0 }
        return seconds / 3600 * hourlyRate
    }
}

/// Lets the AI ask MAIPA-G's own code to put the current phone-staged changes onto the computer
/// before it builds or tests. The app applies the exact staged patch; the AI never retypes it.
public struct SyncStagedToComputerTool: AgentTool {
    public let name = "sync_staged_to_computer"
    let control: ComputerControl
    let workspace: ChangeWorkspace
    let homePath: String
    let cloneURL: String?
    let commit: String?

    public init(control: ComputerControl, workspace: ChangeWorkspace, homePath: String, cloneURL: String?, commit: String?) {
        self.control = control
        self.workspace = workspace
        self.homePath = homePath
        self.cloneURL = cloneURL
        self.commit = commit
    }

    public var spec: ToolSpec {
        ToolSpec(name: name, description: "Make the computer's copy of the repo match the phone-staged changes exactly (MAIPA-G resets the copy to the chat's commit and applies the staged patch). Call it after staging edits and before any build or test.", parameters: [
            "type": "object", "properties": [:], "additionalProperties": false,
        ])
    }

    public func runningSummary(for arguments: JSONValue) -> String { "Putting staged changes on the computer…" }

    public func run(arguments: JSONValue, progress: @escaping @Sendable (String) -> Void) async throws -> ToolOutput {
        let changes = await workspace.stagedChanges()
        let status = try await control.syncStagedChanges(homePath: homePath, cloneURL: cloneURL, commit: commit, changes: changes)
        let shown = status.isEmpty ? "No changed files." : status
        return ToolOutput(forModel: "The computer copy at ~/\(homePath) now matches the staged changes. git status:\n\(shown)", summary: "Synced staged changes to the computer", detail: shown)
    }
}
