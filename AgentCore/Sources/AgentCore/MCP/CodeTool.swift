import Foundation

/// Kiro's `code` tool, on the person's computer: structural search and rewrite with ast-grep, which
/// matches code by its syntax tree rather than its text (`console.log($ARG)` finds every call
/// whatever the argument, and never a match inside a comment or a string).
public struct CodeTool: AgentTool {
    public let name = "code"
    let control: ComputerControl
    let homePath: String?
    let checkout: CheckoutPreparer?

    static let operations = ["pattern_search", "pattern_rewrite"]
    static let notInstalledMarker = "maipa-g-no-ast-grep"
    static let installHint = "Install it on the computer with `npm i -g @ast-grep/cli` (or `brew install ast-grep` on a Mac, or `cargo install ast-grep --locked`), then try again."

    public init(control: ComputerControl, homePath: String?, checkout: CheckoutPreparer? = nil) {
        self.control = control
        self.homePath = homePath
        self.checkout = checkout
    }

    public var spec: ToolSpec {
        ToolSpec(
            name: name,
            description: """
            Structural code search and rewrite with ast-grep on the person's computer (`\(control.machine)`), in the repo's \
            checkout\(homePath.map { " (~/\($0))" } ?? ""). It matches code by its syntax, not its text: in a pattern, $NAME matches \
            any one node (an expression, a name, an argument) and $$$ any number of them, so `console.log($ARG)` finds every \
            console.log call and `func $NAME($$$) async throws` every such Swift function, and comments and strings never match. \
            operation "pattern_search" lists every match with its file and line. operation "pattern_rewrite" replaces each match \
            with rewrite (which can use the same $NAME variables); it is a dry run that shows the changes unless you pass \
            apply: true, which writes the files in the computer's checkout (like a command would: to save them to the repo, make \
            the same change with edit_file, or keep it on the computer). Give language when the pattern alone is ambiguous (swift, \
            typescript, tsx, javascript, python, rust, go, java, kotlin, c, cpp, csharp, ruby, html, css). Don't use it for plain \
            text or regular expressions: use search_code. If ast-grep isn't installed, the result says how to install it.
            """,
            parameters: [
                "type": "object",
                "properties": [
                    "operation": ["type": "string", "enum": .array(Self.operations.map(JSONValue.string)), "description": "pattern_search, or pattern_rewrite (a dry run unless apply is true)."],
                    "pattern": ["type": "string", "description": "The ast-grep pattern, like \"console.log($ARG)\" or \"try! $EXPR\"."],
                    "rewrite": ["type": "string", "description": "For pattern_rewrite: what each match becomes, like \"logger.debug($ARG)\"."],
                    "language": ["type": "string", "description": "The pattern's language, like \"swift\" or \"typescript\". Default: from each file's extension."],
                    "path": ["type": "string", "description": "File or folder to look in, relative to the checkout (or absolute). Default: the whole checkout."],
                    "globs": ["type": "string", "description": "Only these files, like \"*.ts\" or \"!**/test/**\"; separate several with commas."],
                    "context_lines": ["type": "integer", "minimum": 0, "maximum": 10, "description": "For pattern_search: lines to show around each match. Default 0."],
                    "apply": ["type": "boolean", "description": "For pattern_rewrite: write the changes to the files. Default false (only show them)."],
                ],
                "required": ["operation", "pattern"],
                "additionalProperties": false,
            ]
        )
    }

    public var bringsOutsideContent: Bool { true }

    public func runningSummary(for arguments: JSONValue) -> String {
        let pattern = Format.quote(arguments.optionalString("pattern") ?? "", limit: 40)
        switch arguments.optionalString("operation") {
        case "pattern_rewrite": return (arguments.optionalBool("apply") == true ? "Rewriting " : "Previewing a rewrite of ") + pattern + "…"
        default: return "Searching the code for \(pattern)…"
        }
    }

    /// The ast-grep command line for these arguments, without the `cd`.
    static func commandLine(_ arguments: JSONValue) throws -> String {
        let operation = arguments.optionalString("operation") ?? ""
        guard operations.contains(operation) else { throw ToolInputError("operation must be pattern_search or pattern_rewrite.") }
        guard let pattern = arguments["pattern"]?.stringValue, !pattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ToolInputError("Give the ast-grep pattern in `pattern`, like \"console.log($ARG)\".")
        }
        var parts = ["\"$AG\"", "run", "--color", "never", "--pattern", ComputerControl.shellQuote(pattern)]
        if let language = arguments.optionalString("language") {
            guard language.allSatisfy({ $0.isLetter || $0.isNumber || "+#-_".contains($0) }) else { throw ToolInputError("language should be a name like swift or typescript.") }
            parts += ["--lang", ComputerControl.shellQuote(language.lowercased())]
        }
        if operation == "pattern_rewrite" {
            guard let rewrite = arguments["rewrite"]?.stringValue else {
                throw ToolInputError("pattern_rewrite needs `rewrite`: what each match becomes (it may be empty to remove the matches).")
            }
            parts += ["--rewrite", ComputerControl.shellQuote(rewrite)]
            if arguments.optionalBool("apply") == true { parts.append("--update-all") }
        } else if let context = arguments.optionalInt("context_lines"), context > 0 {
            parts += ["--context", String(min(context, 10))]
        }
        if let globs = arguments.optionalString("globs") {
            for glob in globs.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) where !glob.isEmpty {
                parts += ["--globs", ComputerControl.shellQuote(glob)]
            }
        }
        if let path = arguments.optionalString("path") {
            guard !path.contains("\n"), !path.contains("\u{0}") else { throw ToolInputError("path must be one file or folder.") }
            parts += ["--", ComputerControl.shellQuote(path)]
        }
        return parts.joined(separator: " ")
    }

    /// Finds ast-grep as `ast-grep`, or as `sg` when that is ast-grep (on Linux `sg` is often the
    /// unrelated "switch group" command).
    static let findAstGrep = "if command -v ast-grep >/dev/null 2>&1; then AG=ast-grep; elif command -v sg >/dev/null 2>&1 && sg --version 2>/dev/null | grep -qi 'ast-grep'; then AG=sg; else echo \(notInstalledMarker); exit 0; fi; "

    public func run(arguments: JSONValue, progress: @escaping @Sendable (String) -> Void) async throws -> ToolOutput {
        let commandLine = try Self.commandLine(arguments)
        let operation = arguments.optionalString("operation") ?? "pattern_search"
        let applying = operation == "pattern_rewrite" && arguments.optionalBool("apply") == true
        try? await checkout?.ensure()
        let folder = homePath.flatMap { ComputerControl.isSafeRelativePath($0) ? "if [ -d \"$HOME/\($0)\" ]; then cd \"$HOME/\($0)\"; fi; " : nil } ?? ""
        let script = ". \"$HOME/.maipa-g/env.sh\" 2>/dev/null || true; " + folder + Self.findAstGrep + commandLine
        let raw = try await RunCommandTool.withHeartbeat("Running ast-grep", progress: progress) {
            try await control.run(script, timeout: 300)
        }
        let plain = SensitiveDataRedactor().redact(ComputerControl.plainOutput(raw))
        if plain.contains(Self.notInstalledMarker) {
            throw ToolInputError("ast-grep isn't installed on \(control.machine), so the code tool can't run. \(Self.installHint) Until then, search_code with regex: true finds text patterns.")
        }
        let status = RunCommandTool.exitStatus(plain)
        let pattern = Format.quote(arguments.optionalString("pattern") ?? "", limit: 40)
        // ast-grep, like grep, ends with 1 and prints nothing when nothing matched.
        if status.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, status.code <= 1 {
            return ToolOutput(forModel: "No code matches the pattern \(arguments.optionalString("pattern") ?? "").", summary: "Searched the code for \(pattern) · no matches")
        }
        if status.code > 1 || status.code < 0 || (status.code == 1 && status.output.lowercased().contains("error")) {
            throw ToolInputError("ast-grep stopped with exit code \(status.code):\n\(status.output)\nCheck the pattern (it must be valid code in the language) and the language name.")
        }
        let heading: String
        switch (operation, applying) {
        case ("pattern_rewrite", true): heading = "Rewrote the matches of the pattern in the computer's checkout:"
        case ("pattern_rewrite", false): heading = "Dry run: these are the changes pattern_rewrite would make (nothing was written; pass apply: true to write them):"
        default: heading = "Matches of the pattern:"
        }
        return ToolOutput(
            forModel: heading + "\n" + status.output,
            summary: applying ? "Rewrote \(pattern) on the computer" : (operation == "pattern_rewrite" ? "Previewed a rewrite of \(pattern)" : "Searched the code for \(pattern)"),
            detail: String(status.output.prefix(4_000))
        )
    }
}
