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
        return ComputerControl(tools: [tool], machine: machine, commandSizeLimit: nil) { _, arguments in
            let argv = arguments["cmd"]?.arrayValue?.compactMap(\.stringValue) ?? []
            guard argv.count == 3, argv[0] == "bash", argv[1] == "-lc" else {
                return ("MAIPA-G only runs `bash -lc <script>` here.", true)
            }
            // A server started in the background (`expo start … &`) kept open the file the command
            // was watched through, so the command looked busy until its 15 minutes ran out, with
            // its output long finished. The command now runs in a shell that has let go of every
            // file but its input and output, while the outer shell (which holds that file) waits
            // for just the command.
            // The exit code comes back in a file: the process MAIPA-G starts is `setsid`, which hands
            // the shell on and always ends with 0, so a failed build used to look like it worked.
            let exitFile = FileManager.default.temporaryDirectory.appendingPathComponent("maipag-exit-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: exitFile) }
            let result = try await BoundedProcess.run(
                executable: "/bin/bash", arguments: ["-c", runWithoutInheritedFiles, "bash", argv[2], exitFile.path], directory: home,
                environment: childEnvironment, replacingEnvironment: true, timeout: 900, outputLimit: 400_000
            )
            let recorded = (try? String(contentsOf: exitFile, encoding: .utf8)).flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            let exitCode = result.timedOut ? result.exitCode : (recorded ?? result.exitCode)
            var text = result.stdout
            if !result.stderr.isEmpty { text += (text.isEmpty ? "" : "\n") + result.stderr }
            if result.timedOut { text += "\n(the command ran out of time after 15 minutes)" }
            if exitCode != 0 { text += "\n(exit code \(exitCode))" }
            // Like a terminal: a failing command still shows its whole output. Callers that need
            // to know it worked look for their own marker line.
            return (text, false)
        }
    }

    /// Runs `$1` in a login shell that has closed every file except input, output and errors, so
    /// nothing it starts in the background holds the command open after it has finished, and
    /// writes its exit code to the file `$2`.
    static let runWithoutInheritedFiles = """
    (
    if [ -d "/proc/$BASHPID/fd" ]; then for fd in /proc/$BASHPID/fd/*; do fd=${fd##*/}; case "$fd" in 0|1|2) ;; *) eval "exec $fd>&-" 2>/dev/null || true ;; esac; done; fi
    exec /bin/bash -lc "$1"
    )
    code=$?
    if [ -n "$2" ]; then printf '%s\n' "$code" > "$2"; fi
    exit $code
    """

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
