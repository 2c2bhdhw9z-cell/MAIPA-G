import Foundation

// Kiro steering inclusion modes (https://kiro.dev/docs/steering/ "Inclusion modes"): front matter
// at the very top of a `.kiro/steering/*.md` file decides when it is used.
//   inclusion: always            (the default) every interaction
//   inclusion: fileMatch         when working with files matching `fileMatchPattern` (string or list)
//   inclusion: manual            only when referenced with `#name` (or `#steering:name.md`)
//   inclusion: auto              when the request matches `description`
// AGENTS.md files have no inclusion modes and are always included.

public enum SteeringInclusion: Sendable, Hashable {
    case always
    case fileMatch([String])
    case manual
    case auto(name: String, description: String)
}

extension RepoRuleDocument {
    public var isSteeringFile: Bool { path.lowercased().contains(".kiro/steering/") }

    /// The file name without `.md`, which `#name` references use.
    public var steeringName: String {
        let file = path.split(separator: "/").last.map(String.init) ?? path
        return file.lowercased().hasSuffix(".md") ? String(file.dropLast(3)) : file
    }

    public var inclusion: SteeringInclusion {
        guard isSteeringFile, let fields = KiroSteering.frontMatter(text) else { return .always }
        switch fields["inclusion"]?.lowercased() {
        case "filematch":
            let patterns = KiroSteering.list(fields["fileMatchPattern"] ?? "")
            return patterns.isEmpty ? .always : .fileMatch(patterns)
        case "manual":
            return .manual
        case "auto":
            return .auto(name: fields["name"] ?? steeringName, description: fields["description"] ?? "")
        default:
            return .always
        }
    }

    /// True when a fileMatch steering file applies to this repo path.
    public func matchesFile(_ rawPath: String) -> Bool {
        guard case .fileMatch(let patterns) = inclusion else { return false }
        let path = RepoWorkspace.normalize(rawPath)
        return patterns.contains { Glob($0).matches(path) }
    }

    /// Whether `#name` / `#steering:name.md` in the person's message names this file.
    public func isReferenced(by names: Set<String>) -> Bool {
        guard isSteeringFile else { return false }
        let own = steeringName.lowercased()
        if names.contains(own) { return true }
        if case .auto(let name, _) = inclusion, names.contains(name.lowercased()) { return true }
        return false
    }

    /// How the system prompt describes when this document applies.
    public var inclusionLabel: String {
        switch inclusion {
        case .always: return scope.isEmpty ? "always" : "always, for \(scope)/"
        case .fileMatch(let patterns): return "when working on " + patterns.joined(separator: ", ")
        case .manual: return "only when the person references #\(steeringName)"
        case .auto(let name, let description): return "when the request matches: \(description.isEmpty ? name : description)"
        }
    }
}

public enum KiroSteering {
    /// `---\nkey: value\n---` at the very start of the file (no blank lines before it), or nil.
    public static func frontMatter(_ text: String) -> [String: String]? {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        guard normalized.hasPrefix("---\n") else { return nil }
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).dropFirst()
        var fields: [String: String] = [:]
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" { return fields }
            guard let colon = trimmed.firstIndex(of: ":") else { continue }
            let key = trimmed[..<colon].trimmingCharacters(in: .whitespaces)
            let value = trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            fields[key] = unquote(value)
        }
        return nil
    }

    /// `"a"` or `["a", "b"]` → `["a", "b"]`.
    public static func list(_ value: String) -> [String] {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("[") && trimmed.hasSuffix("]") else {
            let single = unquote(trimmed)
            return single.isEmpty ? [] : [single]
        }
        return trimmed.dropFirst().dropLast().split(separator: ",").map { unquote($0.trimmingCharacters(in: .whitespaces)) }.filter { !$0.isEmpty }
    }

    static func unquote(_ value: String) -> String {
        var text = value
        if text.count >= 2, let first = text.first, let last = text.last, first == last, first == "\"" || first == "'" {
            text = String(text.dropFirst().dropLast())
        }
        return text
    }

    /// The documents that apply this turn: always ones, fileMatch ones for the paths in play, and
    /// manual/auto ones the person referenced by name.
    public static func applicable(_ documents: [RepoRuleDocument], paths: [String], referencedNames: Set<String>) -> [RepoRuleDocument] {
        documents.filter { document in
            switch document.inclusion {
            case .always: return true
            case .fileMatch: return paths.contains(where: document.matchesFile) || document.isReferenced(by: referencedNames)
            case .manual, .auto: return document.isReferenced(by: referencedNames)
            }
        }
    }
}

/// Kiro's `#` context providers in a chat message (https://kiro.dev/docs/ide/chat/ "Context providers").
public struct KiroContextReferences: Sendable, Hashable {
    public var specs: [String] = []
    public var steering: [String] = []
    public var files: [String] = []
    public var folders: [String] = []
    public var urls: [String] = []
    public var gitDiff = false
    public var codebase = false
    public var repository = false
    /// Providers that need a desktop editor (#terminal, #problems, #current) and have nothing to read on iPhone.
    public var unavailable: [String] = []

    public var isEmpty: Bool {
        specs.isEmpty && steering.isEmpty && files.isEmpty && folders.isEmpty && urls.isEmpty && !gitDiff && !codebase && !repository && unavailable.isEmpty
    }

    public static func parse(_ message: String) -> KiroContextReferences {
        var refs = KiroContextReferences()
        let lower = message.lowercased()
        if lower.range(of: #"(^|\s)#git\s+diff\b"#, options: .regularExpression) != nil { refs.gitDiff = true }
        guard let regex = try? NSRegularExpression(pattern: #"(?:^|(?<=\s))#([A-Za-z][\w.\-/]*(?::[^\s]+)?)"#) else { return refs }
        let range = NSRange(message.startIndex..., in: message)
        for match in regex.matches(in: message, range: range) {
            guard let tokenRange = Range(match.range(at: 1), in: message) else { continue }
            var token = String(message[tokenRange])
            while let last = token.last, ".,;:!)".contains(last) { token.removeLast() }
            let parts = token.split(separator: ":", maxSplits: 1).map(String.init)
            let key = parts[0].lowercased()
            let value = parts.count > 1 ? parts[1] : ""
            switch key {
            case "spec": if !value.isEmpty { append(&refs.specs, value.trimmingCharacters(in: CharacterSet(charactersIn: "/"))) }
            case "steering":
                if !value.isEmpty {
                    let name = value.lowercased().hasSuffix(".md") ? String(value.dropLast(3)) : value
                    append(&refs.steering, name.lowercased())
                }
            case "file": if !value.isEmpty { append(&refs.files, RepoWorkspace.normalize(value)) }
            case "folder": if !value.isEmpty { append(&refs.folders, RepoWorkspace.normalize(value)) }
            case "url": if !value.isEmpty { append(&refs.urls, value) }
            case "codebase": refs.codebase = true
            case "repository": refs.repository = true
            case "git": break
            case "terminal", "problems", "current": append(&refs.unavailable, "#" + key)
            default:
                if key.hasSuffix("/") {
                    append(&refs.folders, RepoWorkspace.normalize(String(token.dropLast())))
                } else if token.contains(".") || token.contains("/") {
                    append(&refs.files, RepoWorkspace.normalize(token))
                } else {
                    // A bare `#name` is how Kiro includes a manual steering file.
                    append(&refs.steering, key)
                }
            }
        }
        return refs
    }

    private static func append(_ list: inout [String], _ value: String) {
        if !value.isEmpty, !list.contains(value) { list.append(value) }
    }

    /// What the AI is told to fetch before answering. Repo text still arrives through the
    /// read tools, so it stays behind the safety boundary.
    public var promptSection: String {
        guard !isEmpty else { return "" }
        var lines = ["", "", "## Context the person referenced with #"]
        if !specs.isEmpty { lines.append("- Specs: " + specs.map { "`\($0)`" }.joined(separator: ", ") + " — call `load_spec` for each before answering.") }
        if !steering.isEmpty { lines.append("- Steering: " + steering.map { "`#\($0)`" }.joined(separator: ", ") + " — call `load_repo_rules` with `name` for each before answering.") }
        if !files.isEmpty { lines.append("- Files: " + files.map { "`\($0)`" }.joined(separator: ", ") + " — read them with `read_file` before answering.") }
        if !folders.isEmpty { lines.append("- Folders: " + folders.map { "`\($0)/`" }.joined(separator: ", ") + " — list them with `list_files` (and read what matters).") }
        if gitDiff { lines.append("- #git diff: the changes staged in this chat and not saved yet, which are shown to you as staged changes; describe or use those.") }
        if codebase { lines.append("- #codebase: find the relevant files yourself with `search_code` and `list_files`.") }
        if repository { lines.append("- #repository: start from the repo's file tree with `list_files`.") }
        if !urls.isEmpty { lines.append("- Web pages: " + urls.joined(separator: ", ") + " — read them with `read_web_page`.") }
        if !unavailable.isEmpty { lines.append("- " + unavailable.joined(separator: ", ") + " need a desktop editor and have nothing to read on iPhone; say so plainly if they matter.") }
        return lines.joined(separator: "\n")
    }
}
