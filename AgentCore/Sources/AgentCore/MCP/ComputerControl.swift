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

    /// Whether a connector with these tools can serve as a chat computer: one tool runs a command
    /// and takes that command as text or a list. Hugging Face's `hf_sandbox_exec` only takes the
    /// fixed word "exec" there, and a Space's tool has no command at all, so neither counts.
    public static func hasCommandTool(_ tools: [ConnectorToolDefinition]) -> Bool {
        guard let tool = ComputerControl(tools: tools, machine: "check", call: { _, _ in ("", false) }).commandTool,
              let key = commandKey(tool.inputSchema), let property = properties(tool.inputSchema)[key] else { return false }
        return property["enum"] == nil && property["const"] == nil
    }

    /// The tool that runs one command. Sprites names it `exec`, next to `exec_list` and
    /// `exec_kill`, which only list or stop sessions; picking one of those by mistake made every
    /// check fail with `{"count":0,"sessions":[]}`.
    public var commandTool: ConnectorToolDefinition? {
        for exact in ["exec", "execute", "run_command", "exec_command", "run_shell", "shell", "bash", "run"] {
            if let match = tools.first(where: { $0.originalName.lowercased() == exact }) { return match }
        }
        let notRunning: Set<String> = ["list", "get", "kill", "stop", "session", "sessions", "status", "logs", "log", "info", "inspect"]
        return tool { words in
            words.contains(where: { ["exec", "execute", "run", "command", "shell", "bash"].contains($0) }) && !words.contains(where: notRunning.contains)
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
        // Sprites' `exec` takes the program and its arguments as a list (`cmd`, repeatable), so
        // the script runs as `bash -lc <script>` whenever the schema allows a list.
        if Self.allowsArray(Self.properties(tool.inputSchema)[key]) {
            arguments[key] = .array(["bash", "-lc", .string(command)])
        } else {
            arguments[key] = .string(command)
        }
        return .object(arguments)
    }

    static func allowsArray(_ schema: JSONValue?) -> Bool {
        guard let schema else { return false }
        if schema["type"]?.stringValue == "array" || schema["items"] != nil { return true }
        if schema["type"]?.arrayValue?.contains(where: { $0.stringValue == "array" }) == true { return true }
        for key in ["anyOf", "oneOf"] {
            if schema[key]?.arrayValue?.contains(where: { allowsArray($0) }) == true { return true }
        }
        return false
    }

    // MARK: Operations

    /// Runs one command chosen by the app's own code, never by the model.
    public func run(_ command: String) async throws -> String {
        guard let tool = commandTool else { throw Failure.noCommandTool }
        let result = try await call(tool.originalName, commandArguments(command, tool: tool))
        if result.isError { throw Failure.commandFailed(result.text) }
        return result.text
    }

    /// A shell test that is true while MAIPA-G's tool setup runs on the machine. The process is
    /// checked by its command line, as a restarted machine can give its old number to another.
    static let setupRunning = #"{ p=$(cat "$HOME/.maipa-g/setup.pid" 2>/dev/null); [ -n "$p" ] && tr '\0' ' ' 2>/dev/null < "/proc/$p/cmdline" | grep -q 'setup\.sh'; }"#

    /// The health check's real command: it proves the machine starts and runs a shell, and says
    /// whether MAIPA-G's verified tool setup is running (and its current step), finished (and
    /// which tools failed), or hasn't run.
    public static let healthCommand = #"echo maipa-g-health-ok; uname -sm; d="$HOME/.maipa-g"; if "# + setupRunning + #"; then echo maipa-g-tools-installing; grep '^==> ' "$d/setup-run.log" 2>/dev/null | tail -n 1 | cut -c1-124 | sed 's/^==> /maipa-g-tools-step: /'; if grep -qx off "$d/awake" 2>/dev/null; then echo maipa-g-tools-sleeps; fi; elif [ -f "$d/ready" ]; then echo maipa-g-tools-ready; sed -n 's/^failed: /maipa-g-tools-failed: /p' "$d/ready" | cut -c1-300; else echo maipa-g-tools-missing; fi; true"#

    public enum ToolState: Equatable, Sendable { case ready, installing, missing }

    public static func toolState(_ output: String) -> ToolState {
        if output.contains("maipa-g-tools-installing") { return .installing }
        if output.contains("maipa-g-tools-ready") { return .ready }
        return .missing
    }

    /// The setup step running now, such as "Rust 1.99.1 (rustup 1.29.2)".
    public static func setupStep(_ output: String) -> String? { note("maipa-g-tools-step", in: output) }

    /// The tools the finished setup couldn't install, such as "Swift, .NET".
    public static func failedTools(_ output: String) -> String? { note("maipa-g-tools-failed", in: output) }

    /// The machine pauses when idle and couldn't be held awake, so setup only moves on while
    /// the machine is in use.
    public static func setupPausesWhenIdle(_ output: String) -> Bool { output.contains("maipa-g-tools-sleeps") }

    static func note(_ marker: String, in output: String) -> String? {
        for line in plainOutput(output).split(whereSeparator: \.isNewline) {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard text.hasPrefix(marker + ": ") else { continue }
            let value = text.dropFirst(marker.count + 2).trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }
        return nil
    }

    /// The command's own output. A service may wrap it in JSON (`{"stdout": "..."}`).
    static func plainOutput(_ output: String) -> String {
        if let object = JSONValue.parse(Data(output.utf8))?.objectValue {
            let parts = ["stdout", "output", "stderr"].compactMap { object[$0]?.stringValue }
            if !parts.isEmpty { return parts.joined(separator: "\n") }
        }
        return output
    }

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
        if \(Self.setupRunning); then echo maipa-g-setup-started; exit 0; fi
        rm -f "$HOME/.maipa-g/setup.pid"
        curl --proto '=https' --tlsv1.2 -fsSL --retry 3 -o "$HOME/.maipa-g/setup.sh" '\(url)'
        echo '\(sha)  '"$HOME/.maipa-g/setup.sh" | sha256sum -c - >/dev/null
        # Let go of inherited descriptors so this command returns now, while setup keeps going.
        if [ -d /proc/$$/fd ]; then
          for fd in /proc/$$/fd/*; do fd=${fd##*/}; case "$fd" in 0|1|2) ;; *) eval "exec $fd>&-" 2>/dev/null || true ;; esac; done
        fi
        if command -v setsid >/dev/null 2>&1; then
          setsid nohup bash "$HOME/.maipa-g/setup.sh" > "$HOME/.maipa-g/setup-run.log" 2>&1 < /dev/null &
        else
          nohup bash "$HOME/.maipa-g/setup.sh" > "$HOME/.maipa-g/setup-run.log" 2>&1 < /dev/null &
        fi
        # setup.sh writes its own number too; this covers the moment before it starts.
        [ -s "$HOME/.maipa-g/setup.pid" ] || echo $! > "$HOME/.maipa-g/setup.pid"
        echo maipa-g-setup-started
        """
        let output = try await run(script)
        guard output.contains("maipa-g-setup-started") else { throw Failure.commandFailed(output) }
        return "MAIPA-G is installing its checked tool set on \(machine) in the background. It takes about 15 to 30 minutes; progress is in ~/.maipa-g/setup-run.log."
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
        // Sprites can wait for capacity instead of failing when its region is busy.
        if Self.properties(create.inputSchema)["wait_for_capacity"] != nil { arguments["wait_for_capacity"] = true }
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

// MARK: Long commands in the background (Stability 31)

extension ComputerControl {
    /// A tool for keeping the machine running a long command: the service's own background-service
    /// tool when it has one (Sprites keeps a machine with a running service awake), otherwise a
    /// detached shell job. Either way the output goes to ~/.maipa-g/tasks/<id>.log.
    public var serviceTool: ConnectorToolDefinition? {
        tool { ($0.first == "create" || $0.first == "start") && $0.contains(where: { ["service", "services", "task", "tasks"].contains($0) }) }
    }

    static func isTaskID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 40 && id.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
    }

    public func startBackground(_ command: String, homePath: String?, id: String = "task-" + UUID().uuidString.prefix(8).lowercased()) async throws -> String {
        guard Self.isTaskID(id) else { throw Failure.commandFailed("Bad task id") }
        if let homePath { guard Self.isSafeRelativePath(homePath) else { throw Failure.commandFailed("Unsafe checkout path \(homePath)") } }
        let folder = homePath.map { "\"$HOME/\($0)\"" } ?? "\"$HOME\""
        let wrapped = "cd \(folder) && { \(command) ; } ; echo \"maipa-g-exit $?\""
        if let service = serviceTool {
            var arguments: [String: JSONValue] = [:]
            arguments[Self.machineKey(service.inputSchema) ?? "sprite"] = .string(machine)
            let keys = Self.properties(service.inputSchema).keys
            if let nameKey = keys.first(where: { ["name", "service", "service_name", "id"].contains($0) && $0 != Self.machineKey(service.inputSchema) }) {
                arguments[nameKey] = .string(id)
            }
            let commandKey = Self.commandKey(service.inputSchema) ?? "command"
            let logged = "mkdir -p \"$HOME/.maipa-g/tasks\" && (\(wrapped)) > \"$HOME/.maipa-g/tasks/\(id).log\" 2>&1"
            if Self.properties(service.inputSchema)[commandKey]?["type"]?.stringValue == "array" {
                arguments[commandKey] = .array(["bash", "-lc", .string(logged)])
            } else {
                arguments[commandKey] = .string(logged)
            }
            let result = try await call(service.originalName, .object(arguments))
            if result.isError { throw Failure.commandFailed(result.text) }
            return id
        }
        let script = """
        set -eu
        mkdir -p "$HOME/.maipa-g/tasks"
        # Let go of every inherited descriptor, so the command answering this call returns now
        # instead of waiting for the background task to finish.
        if [ -d /proc/$$/fd ]; then
          for fd in /proc/$$/fd/*; do fd=${fd##*/}; case "$fd" in 0|1|2) ;; *) eval "exec $fd>&-" 2>/dev/null || true ;; esac; done
        fi
        # Its own process group, so Stop ends everything the command started.
        if command -v setsid >/dev/null 2>&1; then
          setsid nohup bash -lc \(Self.shellQuote(wrapped)) > "$HOME/.maipa-g/tasks/\(id).log" 2>&1 < /dev/null &
        else
          nohup bash -lc \(Self.shellQuote(wrapped)) > "$HOME/.maipa-g/tasks/\(id).log" 2>&1 < /dev/null &
        fi
        echo $! > "$HOME/.maipa-g/tasks/\(id).pid"
        echo maipa-g-task-started
        """
        let output = try await run(script)
        guard output.contains("maipa-g-task-started") else { throw Failure.commandFailed(output) }
        return id
    }

    /// Whether the task is still running, its exit status when done, and the end of its output.
    public func backgroundStatus(_ id: String) async throws -> String {
        guard Self.isTaskID(id) else { throw Failure.commandFailed("Bad task id") }
        return try await run("""
        log="$HOME/.maipa-g/tasks/\(id).log"; pid_file="$HOME/.maipa-g/tasks/\(id).pid"
        [ -f "$log" ] || { echo "No task \(id) on this machine."; exit 0; }
        # A finished process nobody has collected yet (a zombie) counts as stopped.
        alive() { if [ -r "/proc/$1/stat" ]; then [ "$(cut -d' ' -f3 "/proc/$1/stat")" != "Z" ]; else kill -0 "$1" 2>/dev/null; fi; }
        if grep -q '^maipa-g-exit ' "$log"; then echo "finished: $(grep '^maipa-g-exit ' "$log" | tail -n 1)";
        elif [ -f "$pid_file" ] && ! alive "$(cat "$pid_file")"; then echo "stopped without finishing";
        else echo running; fi
        echo ---; tail -n 60 "$log" | cut -c1-400
        """)
    }

    public func stopBackground(_ id: String) async throws -> String {
        guard Self.isTaskID(id) else { throw Failure.commandFailed("Bad task id") }
        return try await run("""
        pid_file="$HOME/.maipa-g/tasks/\(id).pid"
        alive() { if [ -r "/proc/$1/stat" ]; then [ "$(cut -d' ' -f3 "/proc/$1/stat")" != "Z" ]; else kill -0 "$1" 2>/dev/null; fi; }
        if [ ! -f "$pid_file" ]; then echo "No running task \(id) started by MAIPA-G here."; exit 0; fi
        pid=$(cat "$pid_file")
        kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
        i=0; while alive "$pid" && [ $i -lt 30 ]; do sleep 0.1; i=$((i + 1)); done
        # Anything that ignored the polite stop is ended for certain.
        if alive "$pid"; then kill -KILL -- "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true; fi
        echo "stopped \(id)"
        """)
    }
}

/// Lets the AI run long builds and tests in the background on the chat computer and check them
/// later, instead of one command that times out.
public struct ComputerTaskTool: AgentTool {
    public let name = "computer_task"
    let control: ComputerControl
    let homePath: String?

    public init(control: ComputerControl, homePath: String?) {
        self.control = control
        self.homePath = homePath
    }

    public var spec: ToolSpec {
        ToolSpec(name: name, description: "Run a long command (over a few minutes) in the background on the chat computer, in the repo's copy when the chat has a repo, then check or stop it by id. Output is kept in ~/.maipa-g/tasks/<id>.log.", parameters: [
            "type": "object",
            "properties": [
                "operation": ["type": "string", "enum": ["start", "status", "stop"]],
                "command": ["type": "string", "description": "For start: the shell command."],
                "task_id": ["type": "string", "description": "For status and stop."],
            ],
            "required": ["operation"],
            "additionalProperties": false,
        ])
    }

    public func runningSummary(for arguments: JSONValue) -> String {
        switch arguments["operation"]?.stringValue {
        case "status": "Checking a background task…"
        case "stop": "Stopping a background task…"
        default: "Starting a background task…"
        }
    }

    public var bringsOutsideContent: Bool { true }

    public func approvalRequest(for arguments: JSONValue) async -> ToolApprovalRequest? {
        guard arguments["operation"]?.stringValue == "start" else { return nil }
        let command = arguments["command"]?.stringValue ?? ""
        guard ShellRisk.isRisky(command) else { return nil }
        return ToolApprovalRequest(question: "Allow MAIPA-G to run this in the background on the computer? It can delete files, change the machine or reach other services.\n\(String(command.prefix(500)))", allowLabel: "Run command")
    }

    public func approvalAfterOutsideContent(for arguments: JSONValue) async -> ToolApprovalRequest? {
        guard arguments["operation"]?.stringValue == "start", ShellRisk.reachesNetwork(arguments["command"]?.stringValue ?? "") else { return nil }
        return ToolApprovalRequest(question: "This chat now contains text from the web, a repo or a connector. Allow a background command that reaches the network?\n\(String((arguments["command"]?.stringValue ?? "").prefix(500)))", allowLabel: "Run command")
    }

    public func run(arguments: JSONValue, progress: @escaping @Sendable (String) -> Void) async throws -> ToolOutput {
        if let approval = await approvalRequest(for: arguments) { throw ToolApprovalRequired(approval) }
        return try await runApproved(arguments: arguments, progress: progress)
    }

    public func runApproved(arguments: JSONValue, progress: @escaping @Sendable (String) -> Void) async throws -> ToolOutput {
        switch arguments["operation"]?.stringValue ?? "start" {
        case "status":
            let id = try arguments.requiredString("task_id")
            let text = try await control.backgroundStatus(id)
            return ToolOutput(forModel: text, summary: "Checked background task \(id)", detail: text)
        case "stop":
            let id = try arguments.requiredString("task_id")
            let text = try await control.stopBackground(id)
            return ToolOutput(forModel: text, summary: "Stopped background task \(id)", detail: text)
        case "start":
            let command = try arguments.requiredString("command")
            let id = try await control.startBackground(command, homePath: homePath)
            return ToolOutput(forModel: "Started background task \(id) on \(control.machine). Check it with computer_task status and task_id \(id).", summary: "Started background task \(id)", detail: command)
        default:
            throw ToolInputError("operation must be start, status or stop.")
        }
    }
}
