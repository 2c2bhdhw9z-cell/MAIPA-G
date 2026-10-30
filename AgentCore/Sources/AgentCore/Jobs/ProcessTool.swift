import Foundation
#if os(Linux)
import Glibc
#endif

public struct ProcessResult: Sendable, Hashable {
    public var exitCode: Int32
    public var stdout: String
    public var stderr: String
    public var timedOut: Bool
}

public enum ProcessFailure: Error, Sendable, Equatable {
    case unavailable
    case invalidCommand
    case timedOut
}

public enum BoundedProcess {
    public static func run(
        executable: String,
        arguments: [String],
        directory: URL,
        environment: [String: String] = [:],
        replacingEnvironment: Bool = false,
        stdin: Data? = nil,
        timeout: TimeInterval = 600,
        outputLimit: Int = 80_000
    ) async throws -> ProcessResult {
        #if os(Linux) || os(macOS)
        let manager = FileManager.default
        let temporary = manager.temporaryDirectory.appendingPathComponent("maipag-process-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: temporary) }
        let outputURL = temporary.appendingPathComponent("stdout")
        let errorURL = temporary.appendingPathComponent("stderr")
        _ = manager.createFile(atPath: outputURL.path, contents: nil)
        _ = manager.createFile(atPath: errorURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: outputURL)
        let errors = try FileHandle(forWritingTo: errorURL)
        defer { try? output.close(); try? errors.close() }

        let process = Process()
        #if os(Linux)
        let setsid = "/usr/bin/setsid"
        if manager.isExecutableFile(atPath: setsid) {
            process.executableURL = URL(fileURLWithPath: setsid)
            process.arguments = [executable] + arguments
        } else {
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
        }
        #else
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        #endif
        process.currentDirectoryURL = directory
        if replacingEnvironment {
            process.environment = environment
        } else {
            let home = temporary.appendingPathComponent("home", isDirectory: true)
            let temp = temporary.appendingPathComponent("tmp", isDirectory: true)
            try manager.createDirectory(at: home, withIntermediateDirectories: true)
            try manager.createDirectory(at: temp, withIntermediateDirectories: true)
            var inherited = sanitizedEnvironment(ProcessInfo.processInfo.environment)
            inherited["HOME"] = home.path
            inherited["TMPDIR"] = temp.path
            inherited["XDG_CONFIG_HOME"] = home.appendingPathComponent(".config", isDirectory: true).path
            inherited["XDG_CACHE_HOME"] = home.appendingPathComponent(".cache", isDirectory: true).path
            process.environment = inherited.merging(environment) { _, supplied in supplied }
        }
        process.standardOutput = output
        process.standardError = errors
        if let stdin {
            let input = Pipe()
            process.standardInput = input
            try process.run()
            try input.fileHandleForWriting.write(contentsOf: stdin)
            try input.fileHandleForWriting.close()
        } else {
            try process.run()
        }
        let deadline = Date().addingTimeInterval(max(1, min(timeout, 900)))
        while process.isRunning && Date() < deadline && !Task.isCancelled {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let wasCancelled = Task.isCancelled
        let timedOut = process.isRunning && !wasCancelled
        if process.isRunning {
            #if os(Linux)
            if manager.isExecutableFile(atPath: "/usr/bin/setsid") {
                _ = Glibc.kill(-process.processIdentifier, SIGTERM)
            } else {
                process.terminate()
            }
            #else
            process.terminate()
            #endif
            for _ in 0..<20 where process.isRunning { try? await Task.sleep(nanoseconds: 50_000_000) }
            if process.isRunning {
                #if os(Linux)
                if manager.isExecutableFile(atPath: "/usr/bin/setsid") { _ = Glibc.kill(-process.processIdentifier, SIGKILL) }
                else { process.interrupt() }
                #else
                process.interrupt()
                #endif
            }
        }
        process.waitUntilExit()
        if wasCancelled { throw CancellationError() }
        try output.synchronize(); try errors.synchronize()
        return ProcessResult(
            exitCode: process.terminationStatus,
            stdout: Self.read(outputURL, limit: outputLimit),
            stderr: Self.read(errorURL, limit: outputLimit),
            timedOut: timedOut
        )
        #else
        throw ProcessFailure.unavailable
        #endif
    }

    static func sanitizedEnvironment(_ environment: [String: String]) -> [String: String] {
        // Model-selected commands get an allow-list, not a deny-list. In particular, GitHub
        // Actions control files and *_KEY_FILE indirections must never reach child processes.
        let allowed: Set<String> = ["PATH", "LANG", "LC_ALL", "LC_CTYPE", "TERM", "TZ", "CI"]
        return environment.filter { key, _ in allowed.contains(key.uppercased()) }
    }

    static func minimalChildEnvironment(home: URL, additions: [String: String] = [:]) -> [String: String] {
        let inherited = ProcessInfo.processInfo.environment
        var values = [
            "PATH": inherited["PATH"] ?? "/usr/local/bin:/usr/bin:/bin",
            "HOME": home.path,
            "TMPDIR": home.appendingPathComponent("tmp", isDirectory: true).path,
            "LANG": inherited["LANG"] ?? "C.UTF-8",
        ]
        values.merge(additions) { _, supplied in supplied }
        return values
    }

    private static func read(_ url: URL, limit: Int) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        if size <= UInt64(limit) {
            try? handle.seek(toOffset: 0)
            let data = (try? handle.readToEnd()) ?? Data()
            return String(decoding: data, as: UTF8.self)
        }
        let headCount = max(1, limit / 2)
        let tailCount = max(1, limit - headCount)
        try? handle.seek(toOffset: 0)
        let head = (try? handle.read(upToCount: headCount)) ?? Data()
        try? handle.seek(toOffset: size - UInt64(tailCount))
        let tail = (try? handle.read(upToCount: tailCount)) ?? Data()
        return String(decoding: head, as: UTF8.self)
            + "\n[Output cut: \(size - UInt64(limit)) bytes omitted]\n"
            + String(decoding: tail, as: UTF8.self)
    }
}

/// Read-only repository inspection for report agents on Autonomous runners.
public struct WorkspaceInspectTool: AgentTool {
    public let name = "inspect_workspace"
    public var spec: ToolSpec {
        ToolSpec(name: name, description: "Inspect the checked-out repository without changing it. List files, read one text file, search text, or show Git status/diff.", parameters: [
            "type": "object",
            "properties": [
                "operation": ["type": "string", "enum": ["list", "read", "search", "status", "diff"]],
                "path": ["type": "string"],
                "query": ["type": "string"],
            ],
            "required": ["operation"],
            "additionalProperties": false,
        ])
    }
    private let directory: URL
    public init(directory: URL) { self.directory = directory.standardizedFileURL }
    public func runningSummary(for arguments: JSONValue) -> String { "Inspecting the workspace…" }

    public func run(arguments: JSONValue, progress: @escaping @Sendable (String) -> Void) async throws -> ToolOutput {
        let operation = try arguments.requiredString("operation")
        progress("Inspecting the workspace…")
        let text: String
        switch operation {
        case "list":
            let path = arguments.optionalString("path") ?? ""
            let root = try safeURL(path)
            let values = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
            text = values.sorted { $0.lastPathComponent < $1.lastPathComponent }.prefix(2_000).map { url in
                let folder = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                return url.lastPathComponent + (folder ? "/" : "")
            }.joined(separator: "\n")
        case "read":
            let url = try safeURL(try arguments.requiredString("path"))
            let data = try Data(contentsOf: url)
            guard data.count <= 1_000_000, let value = String(data: data, encoding: .utf8) else { throw ToolInputError("That file is not readable text under 1 MB.") }
            text = value
        case "search":
            let query = try arguments.requiredString("query")
            guard !query.contains("\n"), query.count <= 500 else { throw ToolInputError("Use a shorter one-line search.") }
            let result = try await BoundedProcess.run(executable: "/usr/bin/grep", arguments: ["-R", "-n", "-F", "--exclude-dir=.git", "--", query, "."], directory: directory, timeout: 60)
            text = result.stdout
        case "status":
            let result = try await BoundedProcess.run(executable: "/usr/bin/git", arguments: ["status", "--short"], directory: directory, timeout: 60)
            text = result.stdout
        case "diff":
            let result = try await BoundedProcess.run(executable: "/usr/bin/git", arguments: ["diff", "--", "."], directory: directory, timeout: 60)
            text = result.stdout
        default: throw ToolInputError("Unknown inspection operation.")
        }
        return ToolOutput(forModel: text.isEmpty ? "No results." : text, summary: "Inspected the workspace", detail: String(text.prefix(80_000)))
    }

    private func safeURL(_ path: String) throws -> URL {
        guard SnapshotStore.isSafeRelativePath(path.isEmpty ? "." : path) || path.isEmpty else { throw ToolInputError("That path is outside the repository.") }
        let value = directory.appendingPathComponent(path).standardizedFileURL
        guard value.path == directory.path || value.path.hasPrefix(directory.path + "/") else { throw ToolInputError("That path is outside the repository.") }
        return value
    }
}

/// A real shell inside the checked-out target repo. Its output goes only into the private job
/// transcript; this tool never prints commands, output, prompts, or environment values.
public struct ProcessTool: AgentTool {
    public let name = "run_shell"
    public var spec: ToolSpec {
        ToolSpec(name: name, description: "Run a shell command in the checked-out repository. Use non-interactive commands only.", parameters: [
            "type": "object",
            "properties": [
                "command": ["type": "string"],
                "timeout_seconds": ["type": "integer", "minimum": 1, "maximum": 900],
                "background": ["type": "boolean", "description": "Keep a long command running and return a task id."],
                "operation": ["type": "string", "enum": ["run", "status", "stop"]],
                "task_id": ["type": "string"],
            ],
            "required": ["command"],
            "additionalProperties": false,
        ])
    }

    private let directory: URL
    private let authorization: ChangeAuthorization
    private let rules: RepoWriteRules
    public init(directory: URL, authorization: ChangeAuthorization = ChangeAuthorization(request: ""), rules: RepoWriteRules = RepoWriteRules()) {
        self.directory = directory
        self.authorization = authorization
        self.rules = rules
    }

    public func runningSummary(for arguments: JSONValue) -> String { "Running a command…" }

    public func approvalRequest(for arguments: JSONValue) async -> ToolApprovalRequest? {
        if let operation = arguments.optionalString("operation"), operation != "run" { return nil }
        guard let command = arguments.optionalString("command"), Self.needsApproval(command) else { return nil }
        return ToolApprovalRequest(question: "Allow MAIPA-G to run this command? It may execute code or change files.\n\(String(command.prefix(500)))")
    }

    public func run(arguments: JSONValue, progress: @escaping @Sendable (String) -> Void) async throws -> ToolOutput {
        if let control = try await control(arguments) { return control }
        let command = try arguments.requiredString("command")
        if Self.needsApproval(command) {
            throw ToolApprovalRequired(ToolApprovalRequest(question: "Allow MAIPA-G to run this command? It may execute code or change files.\n\(String(command.prefix(500)))"))
        }
        return try await runOrBackground(arguments: arguments, approved: false, progress: progress)
    }

    public func runApproved(arguments: JSONValue, progress: @escaping @Sendable (String) -> Void) async throws -> ToolOutput {
        if let control = try await control(arguments) { return control }
        return try await runOrBackground(arguments: arguments, approved: true, progress: progress)
    }

    private func control(_ arguments: JSONValue) async throws -> ToolOutput? {
        switch arguments.optionalString("operation") ?? "run" {
        case "run": return nil
        case "status": return await BackgroundCommandRegistry.shared.status(try arguments.requiredString("task_id"))
        case "stop": return await BackgroundCommandRegistry.shared.stop(try arguments.requiredString("task_id"))
        default: throw ToolInputError("Unknown command operation.")
        }
    }

    private func runOrBackground(arguments: JSONValue, approved: Bool, progress: @escaping @Sendable (String) -> Void) async throws -> ToolOutput {
        if arguments["background"]?.boolValue == true {
            let id = await BackgroundCommandRegistry.shared.start {
                try await execute(arguments: arguments, approved: approved, progress: { _ in })
            }
            return ToolOutput(forModel: "Background command started with task id \(id). Use run_shell operation status or stop with this task_id.", summary: "Started background command")
        }
        return try await execute(arguments: arguments, approved: approved, progress: progress)
    }

    static func needsApproval(_ command: String) -> Bool {
        let value = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.contains("\n"),
              !value.contains(where: { ";|&><`$(){}".contains($0) })
        else { return true }
        let words = value.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let first = words.first else { return true }
        if first == "pwd" && words.count == 1 { return false }
        if first == "git", let operation = words.dropFirst().first,
           ["status", "diff", "log", "show"].contains(operation) { return false }
        return true
    }

    private func execute(arguments: JSONValue, approved: Bool, progress: @escaping @Sendable (String) -> Void) async throws -> ToolOutput {
        // One workspace-changing tool at a time: the before/after check must only ever see this
        // command's own changes, never a parallel tool's.
        try await WorkspaceTurnstile.shared.run {
            try await executeAlone(arguments: arguments, approved: approved, progress: progress)
        }
    }

    private func executeAlone(arguments: JSONValue, approved: Bool, progress: @escaping @Sendable (String) -> Void) async throws -> ToolOutput {
        let command = try arguments.requiredString("command")
        guard !command.contains("\u{0}") else { throw ProcessFailure.invalidCommand }
        let timeout = Double(arguments["timeout_seconds"]?.intValue ?? 600)
        let before = try await WorkspaceState.capture(in: directory)
        progress("Running a command…")
        let result = try await BoundedProcess.run(
            executable: "/bin/bash", arguments: ["-lc", command], directory: directory,
            timeout: timeout
        )
        let after = try await WorkspaceState.capture(in: directory)
        if after.head != before.head {
            try await before.restore(in: directory)
            throw ToolInputError("Shell commands cannot commit, switch Git history, or push. MAIPA-G brokers those operations after policy checks.")
        }
        let ruleBlocked = before.paths.subtracting(after.paths).filter { !rules.permitsDeletion(at: $0) }
            + before.buildFiles.changed(comparedWith: after.buildFiles).filter { !rules.permitsBuildSetup(at: $0) }
        if !ruleBlocked.isEmpty {
            try await before.restore(in: directory)
            throw ToolInputError("Repository rules block changes to: \(Array(Set(ruleBlocked)).sorted().joined(separator: ", ")).")
        }
        if !approved {
            let deleted = before.paths.subtracting(after.paths).filter { !authorization.allows(.deletion, path: $0) }.sorted()
            let buildChanged = before.buildFiles.changed(comparedWith: after.buildFiles).filter { !authorization.allows(.buildSetup, path: $0) }
            let blocked = Array(Set(deleted + buildChanged)).sorted()
            if !blocked.isEmpty {
                try await before.restore(in: directory)
                let kind = !deleted.isEmpty && !buildChanged.isEmpty ? "delete files or change build setup" : (!deleted.isEmpty ? "delete files" : "change build setup")
                let shown = blocked.prefix(20).joined(separator: ", ") + (blocked.count > 20 ? ", and \(blocked.count - 20) more" : "")
                throw ToolApprovalRequired(ToolApprovalRequest(question: "Allow this command to \(kind) in: \(shown)?"))
            }
        }
        let combined = [result.stdout, result.stderr].filter { !$0.isEmpty }.joined(separator: "\n")
        if result.timedOut { throw ProcessFailure.timedOut }
        return ToolOutput(
            forModel: "Exit code: \(result.exitCode)\n\(combined)",
            summary: result.exitCode == 0 ? "Command finished" : "Command failed (\(result.exitCode))",
            detail: combined,
            isError: result.exitCode != 0
        )
    }
}

/// Lets one workspace-changing operation run at a time, in arrival order. A model can ask for
/// several tools in one step and they normally run side by side; anything that checks the repo
/// before and after itself (shell commands, connector calls, publishing) goes through here.
public actor WorkspaceTurnstile {
    public static let shared = WorkspaceTurnstile()
    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    public func run<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        if busy {
            await withCheckedContinuation { waiting.append($0) }
        } else {
            busy = true
        }
        defer {
            if waiting.isEmpty { busy = false } else { waiting.removeFirst().resume() }
        }
        return try await body()
    }
}

struct WorkspaceState: Sendable {
    var head: String
    var paths: Set<String>
    var buildFiles: [String: Data]
    var patch: Data

    static func capture(in directory: URL) async throws -> WorkspaceState {
        let listed = try await BoundedProcess.run(
            executable: "/usr/bin/git", arguments: ["ls-files", "-co", "--exclude-standard", "-z"],
            directory: directory, timeout: 120, outputLimit: 20_000_000
        )
        guard listed.exitCode == 0 else { throw CloudRunnerError.commandFailed }
        let candidates = listed.stdout.split(separator: "\0").map(String.init)
        let paths = Set(candidates.filter { path in
            var folder: ObjCBool = false
            return FileManager.default.fileExists(atPath: directory.appendingPathComponent(path).path, isDirectory: &folder) && !folder.boolValue
        })
        var buildFiles: [String: Data] = [:]
        for path in paths where ChangeWorkspace.isBuildSetup(path) {
            buildFiles[path] = try Data(contentsOf: directory.appendingPathComponent(path), options: .mappedIfSafe)
        }
        let add = try await BoundedProcess.run(executable: "/usr/bin/git", arguments: ["add", "-A"], directory: directory, timeout: 120)
        guard add.exitCode == 0 else { throw CloudRunnerError.commandFailed }
        do {
            let diff = try await BoundedProcess.run(
                executable: "/usr/bin/git", arguments: ["diff", "--cached", "--binary", "--full-index"],
                directory: directory, timeout: 120, outputLimit: 90_000_000
            )
            guard diff.exitCode == 0 else { throw CloudRunnerError.commandFailed }
            let reset = try await BoundedProcess.run(executable: "/usr/bin/git", arguments: ["reset"], directory: directory, timeout: 120)
            guard reset.exitCode == 0 else { throw CloudRunnerError.commandFailed }
            let headResult = try await BoundedProcess.run(executable: "/usr/bin/git", arguments: ["rev-parse", "HEAD"], directory: directory, timeout: 60)
            guard headResult.exitCode == 0 else { throw CloudRunnerError.commandFailed }
            return WorkspaceState(head: headResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines), paths: paths, buildFiles: buildFiles, patch: Data(diff.stdout.utf8))
        } catch {
            _ = try? await BoundedProcess.run(executable: "/usr/bin/git", arguments: ["reset"], directory: directory, timeout: 120)
            throw error
        }
    }

    func isSameRepositoryState(as other: WorkspaceState) -> Bool {
        head == other.head && paths == other.paths && buildFiles == other.buildFiles && patch == other.patch
    }

    func restore(in directory: URL) async throws {
        let reset = try await BoundedProcess.run(executable: "/usr/bin/git", arguments: ["reset", "--hard", head], directory: directory, timeout: 120)
        guard reset.exitCode == 0 else { throw CloudRunnerError.commandFailed }
        let clean = try await BoundedProcess.run(executable: "/usr/bin/git", arguments: ["clean", "-fd"], directory: directory, timeout: 120)
        guard clean.exitCode == 0 else { throw CloudRunnerError.commandFailed }
        guard !patch.isEmpty else { return }
        let apply = try await BoundedProcess.run(
            executable: "/usr/bin/git", arguments: ["apply", "--whitespace=nowarn", "-"],
            directory: directory, stdin: patch, timeout: 120
        )
        guard apply.exitCode == 0 else { throw CloudRunnerError.commandFailed }
    }
}

/// Guards the target repository while untrusted connector code runs elsewhere. Connector
/// packages never receive repository access; if one reaches the workspace by an absolute path,
/// every change is restored and the call fails before publication.
struct ConnectorWorkspaceBroker: Sendable {
    private let workspace: URL
    init(workspace: URL) { self.workspace = workspace.standardizedFileURL }

    func snapshot() async throws -> WorkspaceState { try await WorkspaceState.capture(in: workspace) }

    func finish(_ before: WorkspaceState) async throws {
        let after = try await WorkspaceState.capture(in: workspace)
        guard !before.isSameRepositoryState(as: after) else { return }
        try await before.restore(in: workspace)
        throw ToolInputError("Connector packages cannot change repository files directly. Use the repository tools so MAIPA-G can enforce its rules and approvals.")
    }
}

private extension Dictionary where Key == String, Value == Data {
    func changed(comparedWith other: Self) -> [String] {
        Set(keys).union(other.keys).filter { self[$0] != other[$0] }.sorted()
    }
}

public struct StdioMCPServer: Codable, Sendable, Hashable {
    public var id: String
    public var executable: String
    public var arguments: [String]
    public var environment: [String: String]
    public init(id: String, executable: String, arguments: [String] = [], environment: [String: String] = [:]) {
        self.id = id; self.executable = executable; self.arguments = arguments; self.environment = environment
    }
}

/// Bounded JSON-lines stdio transport for local MCP servers on the Linux runner.
public struct StdioMCPTool: AgentTool {
    public let name: String
    public var spec: ToolSpec {
        ToolSpec(name: name, description: "Send one JSON-RPC request to the configured local MCP server.", parameters: [
            "type": "object",
            "properties": ["method": ["type": "string"], "params": ["type": "object"]],
            "required": ["method"],
            "additionalProperties": false,
        ])
    }
    private let server: StdioMCPServer
    private let directory: URL

    public init(server: StdioMCPServer, directory: URL) {
        self.server = server; self.directory = directory
        let safe = server.id.map { $0.isLetter || $0.isNumber ? $0 : "_" }
        name = "mcp_" + String(safe).prefix(48)
    }

    public func runningSummary(for arguments: JSONValue) -> String { "Using \(server.id)…" }

    /// A raw JSON-RPC call gets the same typed approval as a named connector tool: `tools/call`
    /// is judged by the tool it names and its arguments; reads pass; any other method asks.
    public func approvalRequest(for arguments: JSONValue) async -> ToolApprovalRequest? {
        Self.approval(serverID: server.id, arguments: arguments)
    }

    static func approval(serverID: String, arguments: JSONValue) -> ToolApprovalRequest? {
        let method = arguments["method"]?.stringValue ?? ""
        let readMethods: Set<String> = ["initialize", "notifications/initialized", "ping", "tools/list", "resources/list", "resources/read", "resources/templates/list", "prompts/list", "prompts/get", "completion/complete"]
        if readMethods.contains(method) { return nil }
        if method == "tools/call" {
            let toolName = arguments["params"]?["name"]?.stringValue ?? ""
            let definition = ConnectorToolDefinition(serverID: serverID, serverName: serverID, originalName: toolName.isEmpty ? "unnamed" : toolName)
            return ConnectorActionPolicy.approval(for: definition, arguments: arguments["params"]?["arguments"] ?? .object([:]))
        }
        return ToolApprovalRequest(question: "Allow \(String(serverID.prefix(60))) to handle the request “\(String(method.prefix(80)))”? MAIPA-G can't tell what it changes.")
    }

    public func run(arguments: JSONValue, progress: @escaping @Sendable (String) -> Void) async throws -> ToolOutput {
        if let approval = Self.approval(serverID: server.id, arguments: arguments) { throw ToolApprovalRequired(approval) }
        return try await runApproved(arguments: arguments, progress: progress)
    }

    public func runApproved(arguments: JSONValue, progress: @escaping @Sendable (String) -> Void) async throws -> ToolOutput {
        let method = try arguments.requiredString("method")
        let request: JSONValue = [
            "jsonrpc": "2.0", "id": 1, "method": .string(method),
            "params": arguments["params"] ?? .object([:]),
        ]
        let input = Data((request.jsonString() + "\n").utf8)
        progress("Using \(server.id)…")
        // Same isolation as Registry connectors: its own folder, only its declared variables, and
        // anything it changes in the repo is put back before the call can count.
        let server = self.server, workspace = directory
        let result = try await WorkspaceTurnstile.shared.run { () async throws -> ProcessResult in
            let isolation = FileManager.default.temporaryDirectory.appendingPathComponent("maipag-mcp-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: isolation.appendingPathComponent("tmp", isDirectory: true), withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: isolation) }
            let broker = ConnectorWorkspaceBroker(workspace: workspace)
            let before = try await broker.snapshot()
            let result: ProcessResult
            do {
                #if os(Linux)
                let sandbox = try ConnectorSandbox.invocation(command: [server.executable] + server.arguments, directory: isolation)
                result = try await BoundedProcess.run(
                    executable: sandbox.executable, arguments: sandbox.arguments, directory: isolation,
                    environment: BoundedProcess.minimalChildEnvironment(home: isolation, additions: server.environment),
                    replacingEnvironment: true, stdin: input, timeout: 120, outputLimit: 80_000
                )
                #else
                throw ProcessFailure.unavailable
                #endif
            } catch {
                try? await broker.finish(before)
                throw error
            }
            try await broker.finish(before)
            return result
        }
        guard !result.timedOut else { throw ProcessFailure.timedOut }
        let detail = [result.stdout, result.stderr].filter { !$0.isEmpty }.joined(separator: "\n")
        return ToolOutput(forModel: detail, summary: result.exitCode == 0 ? "Used \(server.id)" : "\(server.id) failed", detail: detail, isError: result.exitCode != 0)
    }
}
