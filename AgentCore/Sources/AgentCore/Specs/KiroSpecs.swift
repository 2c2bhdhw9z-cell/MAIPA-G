import Foundation

// Kiro-style specs (owner, 11 November 2026: "So it's Actually like how Kiro does Everything").
//
// A spec is three Markdown files in the chat's repo, never a record inside the app:
// `.kiro/specs/<feature>/requirements.md` (user stories with EARS acceptance criteria),
// `design.md` and `tasks.md` (https://kiro.dev/docs/specs/). They are written in order —
// requirements, then design, then tasks — and each one is approved before the next is written
// (https://kiro.dev/docs/specs/feature-specs/, https://kiro.dev/docs/specs/quick-spec/: Quick Spec
// is the variant "without approval gates"). Tasks are then carried out and checked off in
// `tasks.md` (https://kiro.dev/docs/specs/ "Task Execution").

/// Where a chat's spec is: the document being written or waiting for approval, or building.
public enum KiroSpecPhase: String, Codable, Sendable, CaseIterable {
    case requirements, design, tasks, implementation

    /// The document this phase writes; nil once building.
    public var fileName: String? {
        switch self {
        case .requirements: return "requirements.md"
        case .design: return "design.md"
        case .tasks: return "tasks.md"
        case .implementation: return nil
        }
    }

    public var next: KiroSpecPhase? {
        switch self {
        case .requirements: return .design
        case .design: return .tasks
        case .tasks: return .implementation
        case .implementation: return nil
        }
    }

    public var title: String {
        switch self {
        case .requirements: return "Requirements"
        case .design: return "Design"
        case .tasks: return "Tasks"
        case .implementation: return "Building"
        }
    }

    var rank: Int { Self.allCases.firstIndex(of: self) ?? 0 }
}

/// A chat's spec: which feature folder, and which phase it is in. Stored on the chat.
public struct KiroSpecState: Codable, Sendable, Hashable {
    public var slug: String
    public var phase: KiroSpecPhase

    public init(slug: String, phase: KiroSpecPhase = .requirements) {
        self.slug = slug
        self.phase = phase
    }

    public var folder: String { KiroSpecs.folder + slug + "/" }
    public func path(_ phase: KiroSpecPhase) -> String? { phase.fileName.map { folder + $0 } }
}

/// One line of `tasks.md`: `- [ ] 2.1 Add the login form` or `- [x] 1. Set up the model`.
public struct KiroSpecTask: Sendable, Hashable {
    public var number: String
    public var title: String
    public var isDone: Bool
    public var depth: Int
}

public enum KiroSpecs {
    public static let folder = ".kiro/specs/"
    public static let documents = ["requirements.md", "design.md", "tasks.md"]

    /// `.kiro/specs/<slug>/<document>` → slug, for the three spec documents only.
    public static func slug(fromPath rawPath: String) -> String? {
        let path = RepoWorkspace.normalize(rawPath)
        guard path.hasPrefix(folder) else { return nil }
        let parts = path.dropFirst(folder.count).split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, documents.contains(String(parts[1])), isValidSlug(String(parts[0])) else { return nil }
        return String(parts[0])
    }

    /// Kiro names feature folders in kebab case ("user-authentication").
    public static func isValidSlug(_ slug: String) -> Bool {
        !slug.isEmpty && slug.count <= 80 && slug.first != "-" && slug.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "-") }
    }

    /// Every spec folder that has at least one spec document, from a list of repo paths.
    public static func slugs(in paths: [String]) -> [String] {
        Array(Set(paths.compactMap { slug(fromPath: $0) })).sorted()
    }

    // MARK: Approval gates

    /// Whether a file change is allowed in this phase. nil = allowed; otherwise why not.
    /// Until the tasks are approved, only the spec's own documents up to the current phase can be
    /// written; earlier documents stay editable so they can be revised, as Kiro allows.
    public static func gateRefusal(path rawPath: String, state: KiroSpecState?) -> String? {
        let path = RepoWorkspace.normalize(rawPath)
        guard let state else {
            if let slug = slug(fromPath: path), path == folder + slug + "/requirements.md" { return nil }
            return "Spec mode: no spec has been started in this chat yet, so the only file that can be written is `.kiro/specs/<feature-name>/requirements.md` (kebab-case feature name). Write the requirements first and ask the person to approve them."
        }
        if state.phase == .implementation { return nil }
        let allowed = KiroSpecPhase.allCases
            .filter { $0.rank <= state.phase.rank }
            .compactMap { state.path($0) }
        if allowed.contains(path) { return nil }
        let waiting = state.phase.title.lowercased()
        return "Spec mode: the \(waiting) for `\(state.slug)` haven't been approved yet, so only \(allowed.map { "`\($0)`" }.joined(separator: ", ")) can be written now. Finish `\(state.path(state.phase) ?? state.folder)`, then ask the person to approve it before going further."
    }

    /// The tools that change repo files, which the gate checks.
    public static let gatedTools: Set<String> = ["create_file", "edit_file", "append_file", "delete_file"]

    /// True for a short reply that approves the document just shown ("looks good", "yes, go on"),
    /// and false for anything asking for changes or a question.
    public static func isApproval(_ message: String) -> Bool {
        let lower = message.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lower.isEmpty, lower.count <= 120, !lower.contains("?") else { return false }
        if lower.contains("👍") || lower.contains("✅") { return true }
        let words = lower.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        guard !words.isEmpty, words.count <= 14 else { return false }
        let blockers: Set<String> = ["not", "no", "dont", "don", "but", "change", "instead", "wait", "except", "however", "remove", "add", "fix", "wrong", "missing", "nope", "hold", "stop", "redo", "rewrite"]
        if words.contains(where: blockers.contains) { return false }
        let padded = " " + words.joined(separator: " ") + " "
        let phrases = [
            "looks good", "look good", "looks great", "lgtm", "approve", "approved", "yes", "yep", "yeah", "yup",
            "go", "go ahead", "move on", "next phase", "continue", "proceed", "ship it", "build it", "sounds good",
            "perfect", "ok", "okay", "good to go", "do it", "lets go", "next", "accept", "accepted",
        ]
        return phrases.contains { padded.contains(" \($0) ") }
    }

    /// The phase after the person's message: an approval moves on, but only once the current
    /// phase's document exists; anything else stays put (the AI revises the document).
    public static func afterMessage(_ message: String, state: KiroSpecState, currentDocumentExists: Bool) -> KiroSpecState {
        guard state.phase != .implementation, currentDocumentExists, isApproval(message), let next = state.phase.next else { return state }
        var advanced = state
        advanced.phase = next
        return advanced
    }

    /// After a turn: a chat with no spec yet picks one up from the requirements it just wrote.
    public static func discovered(stagedPaths: [String], current: KiroSpecState?) -> KiroSpecState? {
        if let current { return current }
        let slugs = stagedPaths.compactMap { path -> String? in
            guard let slug = slug(fromPath: path), RepoWorkspace.normalize(path).hasSuffix("/requirements.md") else { return nil }
            return slug
        }
        return slugs.sorted().first.map { KiroSpecState(slug: $0, phase: .requirements) }
    }

    /// An existing spec (already in the repo, so already reviewed there) picked up by `#spec:<name>`:
    /// it resumes at its last document, or builds when `tasks.md` exists.
    public static func resume(slug: String, hasRequirements: Bool, hasDesign: Bool, hasTasks: Bool) -> KiroSpecState {
        if hasTasks { return KiroSpecState(slug: slug, phase: .implementation) }
        if hasDesign { return KiroSpecState(slug: slug, phase: .design) }
        return KiroSpecState(slug: slug, phase: .requirements)
    }

    // MARK: tasks.md

    public static func tasks(in markdown: String) -> [KiroSpecTask] {
        markdown.split(separator: "\n", omittingEmptySubsequences: false).compactMap { rawLine in
            let line = String(rawLine)
            let indent = line.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("- [") || trimmed.hasPrefix("* ["), trimmed.count >= 5 else { return nil }
            let mark = trimmed[trimmed.index(trimmed.startIndex, offsetBy: 3)]
            guard trimmed[trimmed.index(trimmed.startIndex, offsetBy: 4)] == "]" else { return nil }
            let done: Bool
            switch mark {
            case "x", "X": done = true
            case " ", "-", "~": done = false
            default: return nil
            }
            var rest = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
            var number = ""
            if let first = rest.split(separator: " ", maxSplits: 1).first, first.first?.isNumber == true,
               first.allSatisfy({ $0.isNumber || $0 == "." }) {
                number = first.hasSuffix(".") ? String(first.dropLast()) : String(first)
                rest = String(rest.dropFirst(first.count)).trimmingCharacters(in: .whitespaces)
            }
            return KiroSpecTask(number: number, title: rest, isDone: done, depth: indent / 2)
        }
    }

    // MARK: What the AI is told

    /// The Spec-mode section of the system prompt for this phase.
    public static func instructions(state: KiroSpecState?, existingSpecs: [String] = []) -> String {
        var lines = ["", "", "## Spec mode (this chat)",
                     "The person chose Spec for this chat, the way Kiro's Spec mode works. A spec is three Markdown files in the repo under `.kiro/specs/<feature-name>/`: `requirements.md`, `design.md` and `tasks.md`, written in that order. Each one is shown to the person and approved before the next is written; the app only lets you write the current document until then. Plain questions are answered directly and need no spec. Stage the documents with the file tools and save them with `save_changes` so they are in the repo for review."]
        if !existingSpecs.isEmpty {
            lines.append("Specs already in this repo: " + existingSpecs.prefix(40).map { "`\($0)`" }.joined(separator: ", ") + ". Read one with `load_spec` when it is relevant.")
        }
        guard let state else {
            lines.append("""
            No spec has been started in this chat. For a request to build or change something: choose a short kebab-case feature name and write `.kiro/specs/<feature-name>/requirements.md` only. Format:
            # Requirements Document
            ## Introduction
            (what the feature is, in a few sentences)
            ## Requirements
            ### Requirement 1
            **User Story:** As a <role>, I want <feature>, so that <benefit>
            #### Acceptance Criteria
            1. WHEN <event> THEN THE SYSTEM SHALL <response>
            2. IF <precondition> THEN THE SYSTEM SHALL <response>
            (EARS notation; also WHILE <state> and WHERE <feature is included> where they fit; cover edge cases.)
            Use what the conversation has already said. Then stop and ask: "Do the requirements look good? If so, we can move on to the design."
            """)
            return lines.joined(separator: "\n")
        }
        lines.append("This chat's spec: `\(state.folder)`. Call `load_spec` (name `\(state.slug)`) before replying so you work from the current documents.")
        switch state.phase {
        case .requirements:
            lines.append("Phase: requirements, waiting for approval. Revise `\(state.path(.requirements)!)` as the person asks (EARS acceptance criteria), then ask again whether they look good. Do not write the design yet.")
        case .design:
            lines.append("""
            Phase: design. The requirements are approved. Write (or revise) `\(state.path(.design)!)`: Overview, Architecture, Components and Interfaces, Data Models, Error Handling, Testing Strategy (Mermaid diagrams where they help). Research the code first. Then stop and ask: "Does the design look good? If so, we can move on to the implementation plan."
            """)
        case .tasks:
            lines.append("""
            Phase: tasks. The design is approved. Write (or revise) `\(state.path(.tasks)!)`:
            # Implementation Plan
            - [ ] 1. <coding task>
              - <details>
              - _Requirements: 1.1, 2.3_
            - [ ] 2. <next task>
              - [ ] 2.1 <sub-task>
            Only coding tasks (writing, changing or testing code), each small, building on the previous ones and referring to the requirements it covers. Then stop and ask: "Do the tasks look good?"
            """)
        case .implementation:
            lines.append("""
            Phase: building. The tasks are approved. When the person asks to run a task, do exactly that task (and its sub-tasks); with no task named, do the next unchecked one. Run all tasks only when asked. Check each finished task off by changing `- [ ]` to `- [x]` in `\(state.path(.tasks)!)`, verify the work, save, then stop and say what was done and which task is next. If you must depart from the design, say so and update the spec.
            """)
        }
        return lines.joined(separator: "\n")
    }
}

/// Wraps the file-changing tools so Spec mode's approval gates are enforced in code, not just asked for.
public struct KiroSpecGatedTool: AgentTool {
    let inner: any AgentTool
    let state: @Sendable () -> KiroSpecState?

    public init(_ inner: any AgentTool, state: @escaping @Sendable () -> KiroSpecState?) {
        self.inner = inner
        self.state = state
    }

    public static func wrap(_ tools: [any AgentTool], state: @escaping @Sendable () -> KiroSpecState?) -> [any AgentTool] {
        tools.map { KiroSpecs.gatedTools.contains($0.name) ? KiroSpecGatedTool($0, state: state) : $0 }
    }

    public var name: String { inner.name }
    public var spec: ToolSpec { inner.spec }
    public var bringsOutsideContent: Bool { inner.bringsOutsideContent }
    public func runningSummary(for arguments: JSONValue) -> String { inner.runningSummary(for: arguments) }
    public func approvalRequest(for arguments: JSONValue) async -> ToolApprovalRequest? {
        refusal(arguments) == nil ? await inner.approvalRequest(for: arguments) : nil
    }
    public func approvalAfterOutsideContent(for arguments: JSONValue) async -> ToolApprovalRequest? {
        refusal(arguments) == nil ? await inner.approvalAfterOutsideContent(for: arguments) : nil
    }

    func refusal(_ arguments: JSONValue) -> ToolOutput? {
        let path = arguments["path"]?.stringValue ?? ""
        guard let reason = KiroSpecs.gateRefusal(path: path, state: state()) else { return nil }
        return ToolOutput(forModel: reason, summary: "Waiting for spec approval", detail: reason, isError: true)
    }

    public func run(arguments: JSONValue, progress: @escaping @Sendable (String) -> Void) async throws -> ToolOutput {
        if let refused = refusal(arguments) { return refused }
        return try await inner.run(arguments: arguments, progress: progress)
    }
    public func runLive(arguments: JSONValue, update: @escaping @Sendable (ToolLiveUpdate) -> Void) async throws -> ToolOutput {
        if let refused = refusal(arguments) { return refused }
        return try await inner.runLive(arguments: arguments, update: update)
    }
    public func runLive(arguments: JSONValue, callID: String, existingSubagents: [SubagentRunItem]?, update: @escaping @Sendable (ToolLiveUpdate) -> Void) async throws -> ToolOutput {
        if let refused = refusal(arguments) { return refused }
        return try await inner.runLive(arguments: arguments, callID: callID, existingSubagents: existingSubagents, update: update)
    }
    public func runApproved(arguments: JSONValue, progress: @escaping @Sendable (String) -> Void) async throws -> ToolOutput {
        if let refused = refusal(arguments) { return refused }
        return try await inner.runApproved(arguments: arguments, progress: progress)
    }
    public func runApprovedLive(arguments: JSONValue, update: @escaping @Sendable (ToolLiveUpdate) -> Void) async throws -> ToolOutput {
        if let refused = refusal(arguments) { return refused }
        return try await inner.runApprovedLive(arguments: arguments, update: update)
    }
    public func runApprovedLive(arguments: JSONValue, callID: String, existingSubagents: [SubagentRunItem]?, update: @escaping @Sendable (ToolLiveUpdate) -> Void) async throws -> ToolOutput {
        if let refused = refusal(arguments) { return refused }
        return try await inner.runApprovedLive(arguments: arguments, callID: callID, existingSubagents: existingSubagents, update: update)
    }
}

/// Reads a spec's three documents from the chat's repo (staged changes included), like Kiro's
/// `#spec` context provider. Repo text, so it is outside content under the safety boundary.
public struct LoadSpecTool: AgentTool {
    public typealias Reader = @Sendable (String) async -> String?
    public typealias Lister = @Sendable () async -> [String]
    public let name = "load_spec"
    let read: Reader
    let list: Lister

    public init(read: @escaping Reader, list: @escaping Lister) {
        self.read = read
        self.list = list
    }

    public var bringsOutsideContent: Bool { true }

    public var spec: ToolSpec {
        ToolSpec(
            name: name,
            description: "Read a Kiro spec from the repo: .kiro/specs/<name>/requirements.md, design.md and tasks.md. Leave name empty to list the specs.",
            parameters: [
                "type": "object",
                "properties": ["name": ["type": "string", "description": "The spec's folder name, like \"user-authentication\"."]],
                "additionalProperties": false,
            ]
        )
    }

    public func runningSummary(for arguments: JSONValue) -> String {
        arguments.optionalString("name").map { "Reading spec \($0)…" } ?? "Listing specs…"
    }

    public func run(arguments: JSONValue, progress: @escaping @Sendable (String) -> Void) async throws -> ToolOutput {
        let specs = KiroSpecs.slugs(in: await list())
        let requested = (arguments.optionalString("name") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ".kiro/specs/", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !requested.isEmpty else {
            let text = specs.isEmpty ? "This repo has no specs in .kiro/specs/ yet." : "Specs in .kiro/specs/: " + specs.joined(separator: ", ")
            return ToolOutput(forModel: text, summary: "Listed \(specs.count) spec\(specs.count == 1 ? "" : "s")")
        }
        guard KiroSpecs.isValidSlug(requested) else {
            return ToolOutput(forModel: "\(requested) isn't a spec name. Specs: \(specs.joined(separator: ", "))", summary: "No such spec", isError: true)
        }
        var sections: [String] = []
        for document in KiroSpecs.documents {
            let path = KiroSpecs.folder + requested + "/" + document
            if let text = await read(path) {
                sections.append("--- \(path) ---\n\(String(text.prefix(40_000)))")
            } else {
                sections.append("--- \(path) --- (not written yet)")
            }
        }
        let found = sections.filter { !$0.hasSuffix("(not written yet)") }.count
        guard found > 0 else {
            return ToolOutput(forModel: "No spec named \(requested) yet." + (specs.isEmpty ? "" : " Specs: " + specs.joined(separator: ", ")), summary: "No such spec", isError: false)
        }
        let text = sections.joined(separator: "\n\n")
        return ToolOutput(forModel: text, summary: "Read spec \(requested) (\(found) of 3 documents)", detail: text)
    }
}
