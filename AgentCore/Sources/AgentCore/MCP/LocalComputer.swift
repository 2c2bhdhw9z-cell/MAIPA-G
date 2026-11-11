import Foundation

extension ComputerControl {
    /// The command tool as the runner on the chat computer has it: commands run right here, in a
    /// real login shell, instead of through the Sprites connector. The rest of ComputerControl
    /// (staged-file sync, background tasks, hooks) works unchanged on top of it.
    ///
    /// Commands get a clean environment: HOME, PATH, the user and the language, never a key.
    public static func local(machine: String, home: URL, environment: [String: String] = ProcessInfo.processInfo.environment) -> ComputerControl {
        let tool = ConnectorToolDefinition(
            serverID: "local", serverName: "This computer", originalName: "exec",
            description: "Run a command on this computer.",
            inputSchema: ["type": "object", "properties": ["cmd": ["type": "array", "items": ["type": "string"]]], "required": ["cmd"]]
        )
        let childEnvironment = localEnvironment(home: home, from: environment)
        return ComputerControl(tools: [tool], machine: machine) { _, arguments in
            let argv = arguments["cmd"]?.arrayValue?.compactMap(\.stringValue) ?? []
            guard argv.count == 3, argv[0] == "bash", argv[1] == "-lc" else {
                return ("MAIPA-G only runs `bash -lc <script>` here.", true)
            }
            let result = try await BoundedProcess.run(
                executable: "/bin/bash", arguments: ["-lc", argv[2]], directory: home,
                environment: childEnvironment, replacingEnvironment: true, timeout: 900, outputLimit: 400_000
            )
            var text = result.stdout
            if !result.stderr.isEmpty { text += (text.isEmpty ? "" : "\n") + result.stderr }
            if result.timedOut { text += "\n(the command ran out of time after 15 minutes)" }
            if result.exitCode != 0 { text += "\n(exit code \(result.exitCode))" }
            // Like a terminal: a failing command still shows its whole output. Callers that need
            // to know it worked look for their own marker line.
            return (text, false)
        }
    }

    static func localEnvironment(home: URL, from environment: [String: String]) -> [String: String] {
        var values: [String: String] = [
            "HOME": home.path,
            "PATH": environment["PATH"] ?? "/usr/local/bin:/usr/bin:/bin",
            "LANG": environment["LANG"] ?? "C.UTF-8",
            "TERM": "dumb",
        ]
        for key in ["USER", "LOGNAME", "SHELL", "TZ", "LC_ALL"] { if let value = environment[key] { values[key] = value } }
        return values
    }
}
