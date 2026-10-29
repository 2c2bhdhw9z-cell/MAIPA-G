import Foundation

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
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, supplied in supplied }
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
            process.terminate()
            for _ in 0..<20 where process.isRunning { try? await Task.sleep(nanoseconds: 50_000_000) }
            if process.isRunning { process.interrupt() }
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

    private static func read(_ url: URL, limit: Int) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: limit + 1)) ?? Data()
        let clipped = data.count > limit
        let text = String(decoding: data.prefix(limit), as: UTF8.self)
        return clipped ? text + "\n[Output cut off]" : text
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
            ],
            "required": ["command"],
            "additionalProperties": false,
        ])
    }

    private let directory: URL
    public init(directory: URL) { self.directory = directory }

    public func runningSummary(for arguments: JSONValue) -> String { "Running a command…" }

    public func approvalRequest(for arguments: JSONValue) async -> ToolApprovalRequest? {
        let command = arguments["command"]?.stringValue?.lowercased() ?? ""
        let destructive = ["rm ", "rm\t", "git clean", "unlink ", "rmdir "].contains { command.contains($0) }
        if destructive { return ToolApprovalRequest(question: "Allow this command to delete files?", allowLabel: "Allow") }
        let buildSetup = [".github/workflows/", "project.yml", "package.swift", "dockerfile"].contains { command.contains($0) }
        if buildSetup { return ToolApprovalRequest(question: "Allow this command to change the repo's build setup?", allowLabel: "Allow") }
        return nil
    }

    public func run(arguments: JSONValue, progress: @escaping @Sendable (String) -> Void) async throws -> ToolOutput {
        let command = try arguments.requiredString("command")
        guard !command.contains("\u{0}") else { throw ProcessFailure.invalidCommand }
        let timeout = Double(arguments["timeout_seconds"]?.intValue ?? 600)
        progress("Running a command…")
        let result = try await BoundedProcess.run(
            executable: "/bin/bash", arguments: ["-lc", command], directory: directory,
            timeout: timeout
        )
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

    public func run(arguments: JSONValue, progress: @escaping @Sendable (String) -> Void) async throws -> ToolOutput {
        let method = try arguments.requiredString("method")
        let request: JSONValue = [
            "jsonrpc": "2.0", "id": 1, "method": .string(method),
            "params": arguments["params"] ?? .object([:]),
        ]
        let input = Data((request.jsonString() + "\n").utf8)
        progress("Using \(server.id)…")
        let result = try await BoundedProcess.run(
            executable: server.executable, arguments: server.arguments, directory: directory,
            environment: server.environment, stdin: input, timeout: 120, outputLimit: 80_000
        )
        guard !result.timedOut else { throw ProcessFailure.timedOut }
        let detail = [result.stdout, result.stderr].filter { !$0.isEmpty }.joined(separator: "\n")
        return ToolOutput(forModel: detail, summary: result.exitCode == 0 ? "Used \(server.id)" : "\(server.id) failed", detail: detail, isError: result.exitCode != 0)
    }
}
