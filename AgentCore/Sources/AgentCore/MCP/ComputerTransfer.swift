import Foundation

/// Gives MAIPA-G's own code a GitHub token when a private repo has to be copied onto the computer.
public typealias CheckoutToken = @Sendable () async -> String?

// MARK: Files onto the computer

extension ComputerControl {
    /// The service's own file-writing tool (Sprites calls it `file_write`). Its content travels in
    /// the request body, so it isn't held to the address-length limit that `exec` has.
    public var fileWriteTool: ConnectorToolDefinition? {
        for exact in ["file_write", "write_file", "fs_write", "files_write", "write"] {
            if let match = tools.first(where: { $0.originalName.lowercased() == exact }) { return match }
        }
        return tool { words in
            words.contains("write") && words.contains(where: { ["file", "files", "fs"].contains($0) })
                && !words.contains(where: { ["read", "list", "delete", "rename", "copy"].contains($0) })
        }
    }

    /// Raw bytes per call to the file tool (sent as base64 text, a third bigger).
    static let filePieceBytes = 1_000_000
    /// Raw bytes per command when there is no file tool: small enough that the script stays under
    /// the command size limit once base64 and the few lines around it are added.
    static let commandPieceBytes = 1_200

    /// Writes `data` to `~/<path>` on the computer, readable only by the computer's user. It goes
    /// through the service's file tool when there is one, in pieces, and is put together and
    /// checked with one short command; otherwise in short commands of a kilobyte or so each.
    public func writeFile(_ data: Data, toHomePath path: String) async throws {
        guard Self.isSafeRelativePath(path) else { throw Failure.commandFailed("Unsafe file path \(path)") }
        guard commandSizeLimit != nil else {
            // Commands run right here, where only Linux's 128 KB limit on one argument applies.
            try await writeThroughCommands(data, path: path, pieceBytes: 60_000)
            return
        }
        if let writer = fileWriteTool {
            do {
                try await writeThroughFileTool(writer, data, path: path)
                return
            } catch {
                // An unexpected file tool must not stop the work: short commands always work.
            }
        }
        try await writeThroughCommands(data, path: path, pieceBytes: Self.commandPieceBytes)
    }

    func writeThroughFileTool(_ writer: ConnectorToolDefinition, _ data: Data, path: String) async throws {
        let prepared = try await runInline("umask 077; mkdir -p \"$HOME/.maipa-g/incoming\" && printf 'maipa-g-home: %s\\n' \"$HOME\"")
        guard let home = Self.note("maipa-g-home", in: prepared), home.hasPrefix("/"), !home.contains("'") else {
            throw Failure.commandFailed("The computer didn't say where its home folder is.")
        }
        let tag = UUID().uuidString.prefix(12).lowercased()
        var pieces: [Data] = []
        var offset = 0
        repeat {
            let end = min(offset + Self.filePieceBytes, data.count)
            pieces.append(data.subdata(in: offset..<end))
            offset = end
        } while offset < data.count
        for (index, piece) in pieces.enumerated() {
            let arguments = fileWriteArguments(writer, absolutePath: "\(home)/.maipa-g/incoming/\(tag).\(index).b64", content: piece.base64EncodedString(), home: home)
            let result = try await call(writer.originalName, arguments)
            if result.isError { throw Failure.commandFailed(Self.withoutShellNoise(result.text)) }
        }
        let output = try await runInline(Self.assembleScript(tag: tag, count: pieces.count, path: path, bytes: data.count))
        guard output.contains("maipa-g-write-ok") else { throw Failure.commandFailed(output) }
    }

    static func assembleScript(tag: String, count: Int, path: String, bytes: Int) -> String {
        """
        set -eu
        umask 077
        in="$HOME/.maipa-g/incoming"; f="$HOME/\(path)"
        mkdir -p "$(dirname "$f")"
        i=0; while [ $i -lt \(count) ]; do cat "$in/\(tag).$i.b64"; i=$((i + 1)); done | base64 -d > "$f.part"
        rm -f "$in/\(tag)."*.b64
        [ "$(stat -c %s "$f.part")" = "\(bytes)" ] || { rm -f "$f.part"; echo "maipa-g-write-short"; exit 1; }
        mv -f "$f.part" "$f"
        echo maipa-g-write-ok
        """
    }

    func fileWriteArguments(_ tool: ConnectorToolDefinition, absolutePath: String, content: String, home: String) -> JSONValue {
        let properties = Self.properties(tool.inputSchema)
        var arguments: [String: JSONValue] = [:]
        if let key = Self.machineKey(tool.inputSchema) { arguments[key] = .string(machine) }
        let pathKey = ["path", "file_path", "filePath", "filename", "file"].first { properties[$0] != nil } ?? "path"
        let contentKey = ["content", "contents", "data", "text", "body"].first { properties[$0] != nil } ?? "content"
        arguments[pathKey] = .string(absolutePath)
        arguments[contentKey] = .string(content)
        for key in ["workingDir", "working_dir", "workdir", "cwd"] where properties[key] != nil { arguments[key] = .string(home) }
        for key in ["mkdir", "create_dirs", "createDirs", "parents", "mkdirs"] where properties[key] != nil { arguments[key] = true }
        for key in ["mode", "permissions"] where properties[key]?["type"]?.stringValue != "integer" && properties[key] != nil { arguments[key] = .string("0600") }
        return .object(arguments)
    }

    func writeThroughCommands(_ data: Data, path: String, pieceBytes: Int) async throws {
        for script in Self.pieceScripts(data, path: path, pieceBytes: pieceBytes) {
            let output = try await runInline(script)
            guard output.contains("maipa-g-write-ok") else { throw Failure.commandFailed(output) }
        }
    }

    static func pieceScripts(_ data: Data, path: String, pieceBytes: Int) -> [String] {
        let file = "\"$HOME/\(path)\""
        var pieces: [Data] = []
        var offset = 0
        repeat {
            let end = min(offset + max(1, pieceBytes), data.count)
            pieces.append(data.subdata(in: offset..<end))
            offset = end
        } while offset < data.count
        return pieces.enumerated().map { index, piece in
            var script = "set -eu\numask 077\n"
            if index == 0 { script += "mkdir -p \"$(dirname \(file))\"\n: > \(file).part\n" }
            script += "printf %s '\(piece.base64EncodedString())' | base64 -d >> \(file).part\n"
            if index == pieces.count - 1 {
                script += "[ \"$(stat -c %s \(file).part)\" = \"\(data.count)\" ] || { echo maipa-g-write-short; exit 1; }\n"
                script += "mv -f \(file).part \(file)\n"
            }
            script += "echo maipa-g-write-ok\n"
            return script
        }
    }
}

// MARK: The repo's copy on the computer

extension ComputerControl {
    /// Makes sure `~/<homePath>` is a clone of the repo that has `commit`. A private GitHub repo
    /// is cloned with `token`, which goes to git through its environment from a file only the
    /// computer's user can read, deleted before git starts. A folder that is in the way but isn't
    /// a clone is moved aside, never deleted.
    public func ensureCheckout(homePath: String, cloneURL: String, commit: String?, token: CheckoutToken?) async throws {
        guard Self.isSafeRelativePath(homePath) else { throw Failure.commandFailed("Unsafe checkout path \(homePath)") }
        guard Self.isPublicCloneURL(cloneURL) else { throw Failure.commandFailed("MAIPA-G can't use that clone address.") }
        let validCommit = commit.flatMap { $0.count >= 7 && $0.count <= 64 && $0.allSatisfy(\.isHexDigit) ? $0 : nil }
        let path = "\"$HOME/\(homePath)\""
        var check = "if [ -d \(path)/.git ]; then echo maipa-g-checkout-present; "
        if let validCommit { check += "git -C \(path) cat-file -e '\(validCommit)^{commit}' 2>/dev/null && echo maipa-g-commit-present; " }
        check += "else echo maipa-g-checkout-missing; fi; true"
        let state = try await runInline(check)
        if state.contains("maipa-g-checkout-present"), validCommit == nil || state.contains("maipa-g-commit-present") { return }

        var headerPath: String?
        if cloneURL.hasPrefix("https://github.com/"), let token, let value = await token(), !value.isEmpty {
            let header = "AUTHORIZATION: basic " + Data("x-access-token:\(value)".utf8).base64EncodedString()
            let name = ".maipa-g/secrets/git-\(UUID().uuidString.prefix(12).lowercased())"
            try await writeFile(Data(header.utf8), toHomePath: name)
            headerPath = name
        }
        let output = try await run(Self.checkoutScript(homePath: homePath, cloneURL: cloneURL, commit: validCommit, headerPath: headerPath))
        if output.contains("maipa-g-checkout-ok") { return }
        let detail = Self.plainOutput(output).replacingOccurrences(of: "maipa-g-clone-failed", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        let repoName = cloneURL.replacingOccurrences(of: "https://github.com/", with: "").replacingOccurrences(of: ".git", with: "")
        throw Failure.commandFailed("Couldn't copy \(repoName) onto the computer\(headerPath == nil && cloneURL.hasPrefix("https://github.com/") ? " (no GitHub token was available for it)" : ""): \(String(detail.suffix(400)))")
    }

    static func checkoutScript(homePath: String, cloneURL: String, commit: String?, headerPath: String?) -> String {
        var script = """
        set -u
        umask 077
        p="$HOME/\(homePath)"
        export GIT_TERMINAL_PROMPT=0

        """
        if let headerPath {
            script += """
            h="$HOME/\(headerPath)"
            hv=$(cat "$h" 2>/dev/null || true); rm -f "$h"
            export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0='http.https://github.com/.extraheader' GIT_CONFIG_VALUE_0="$hv"
            unset hv

            """
        }
        script += """
        if [ ! -d "$p/.git" ]; then
          if [ -e "$p" ]; then mv "$p" "$p.before-maipa-g-$(date +%s)"; fi
          mkdir -p "$(dirname "$p")"
          git clone --quiet '\(cloneURL)' "$p" 2>&1 | tail -n 5 || true
          [ -d "$p/.git" ] || { echo maipa-g-clone-failed; exit 4; }
        fi

        """
        if let commit {
            script += "git -C \"$p\" cat-file -e '\(commit)^{commit}' 2>/dev/null || git -C \"$p\" fetch --quiet origin '\(commit)' 2>/dev/null || git -C \"$p\" fetch --quiet origin 2>&1 | tail -n 3 || true\n"
        } else {
            script += "git -C \"$p\" fetch --quiet origin 2>&1 | tail -n 3 || true\n"
        }
        script += "echo maipa-g-checkout-ok\n"
        return script
    }

    /// The command output without the shell's noise: Sprites marks each piece of output with a
    /// control byte and ends with one carrying the exit code, and the Sprite's `.bashrc` warns
    /// about line editing on every login shell. A failing exit code is kept as a plain line.
    public static func withoutShellNoise(_ text: String) -> String {
        var scalars = Array(text.unicodeScalars)
        var exitCode: UInt32?
        if let marker = scalars.lastIndex(where: { $0.value == 3 }), marker + 1 >= scalars.count - 1 {
            if marker + 1 < scalars.count, scalars[marker + 1].value < 256 { exitCode = scalars[marker + 1].value }
            scalars.removeSubrange(marker...)
        }
        let cleaned = String(String.UnicodeScalarView(scalars.filter { $0.value > 3 }))
        var lines = cleaned.components(separatedBy: "\n").filter {
            !($0.contains(".bashrc: line ") && $0.contains("bind: warning: line editing not enabled"))
        }
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty, lines.count > 1 { lines.removeLast() }
        var result = lines.joined(separator: "\n")
        if let exitCode, exitCode != 0 { result += (result.isEmpty ? "" : "\n") + "(exit code \(exitCode))" }
        return result
    }
}

/// Copies the repo onto the computer the first time a command needs it, once per reply.
public actor CheckoutPreparer {
    let control: ComputerControl
    let homePath: String
    let cloneURL: String
    let commit: String?
    let token: CheckoutToken?
    private var done = false
    private var running: Task<Void, Error>?

    public init(control: ComputerControl, homePath: String, cloneURL: String, commit: String?, token: CheckoutToken?) {
        self.control = control
        self.homePath = homePath
        self.cloneURL = cloneURL
        self.commit = commit
        self.token = token
    }

    public func ensure() async throws {
        if done { return }
        if let running { return try await running.value }
        let task = Task { [control, homePath, cloneURL, commit, token] in
            try await control.ensureCheckout(homePath: homePath, cloneURL: cloneURL, commit: commit, token: token)
        }
        running = task
        do {
            try await task.value
            done = true
            running = nil
        } catch {
            running = nil
            throw error
        }
    }
}
