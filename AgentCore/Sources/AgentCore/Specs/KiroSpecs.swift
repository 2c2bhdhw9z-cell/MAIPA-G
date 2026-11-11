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

/// Which Kiro spec workflow a spec follows (owner, 11 November 2026: "Add Kiro's other spec types").
/// - Requirements-First: Requirements → Design → Tasks (https://kiro.dev/docs/specs/feature-specs/).
/// - Design-First: Design → Requirements → Tasks (same page, "Workflow Variants").
/// - Bugfix: `bugfix.md` (current, expected and unchanged behaviour) → Design → Tasks
///   (https://kiro.dev/docs/specs/bugfix-specs/).
/// - Quick Spec: all three documents in one pass with no approval gates between them, landing on
///   the task list (https://kiro.dev/docs/specs/quick-spec/).
public enum KiroSpecKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case requirementsFirst, designFirst, bugfix, quick

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .requirementsFirst: return "Requirements-First"
        case .designFirst: return "Design-First"
        case .bugfix: return "Bug Fix"
        case .quick: return "Quick Spec"
        }
    }

    public var explanation: String {
        switch self {
        case .requirementsFirst: return "requirements, then design, then tasks"
        case .designFirst: return "design, then requirements, then tasks"
        case .bugfix: return "bug analysis, fix design, then tasks"
        case .quick: return "all three at once, no approval stops"
        }
    }

    /// The document phases in the order this workflow writes them, then building.
    public var order: [KiroSpecPhase] {
        switch self {
        case .designFirst: return [.design, .requirements, .tasks, .implementation]
        default: return [.requirements, .design, .tasks, .implementation]
        }
    }

    /// Quick Spec has no approval gates between its documents.
    public var hasGates: Bool { self != .quick }

    /// The first document this workflow writes.
    public var firstPhase: KiroSpecPhase { order[0] }
}

/// A chat's spec: which feature folder, which workflow, and which phase it is in. Stored on the chat.
public struct KiroSpecState: Codable, Sendable, Hashable {
    public var slug: String
    public var phase: KiroSpecPhase
    public var kind: KiroSpecKind

    public init(slug: String, phase: KiroSpecPhase = .requirements, kind: KiroSpecKind = .requirementsFirst) {
        self.slug = slug
        self.phase = phase
        self.kind = kind
    }

    enum CodingKeys: String, CodingKey { case slug, phase, kind }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        slug = try c.decode(String.self, forKey: .slug)
        phase = try c.decode(KiroSpecPhase.self, forKey: .phase)
        kind = try c.decodeIfPresent(KiroSpecKind.self, forKey: .kind) ?? .requirementsFirst
    }

    public var folder: String { KiroSpecs.folder + slug + "/" }

    /// The file a phase writes. A Bugfix spec's first document is `bugfix.md`, not `requirements.md`.
    public func path(_ phase: KiroSpecPhase) -> String? {
        guard let name = phase.fileName else { return nil }
        if phase == .requirements, kind == .bugfix { return folder + "bugfix.md" }
        return folder + name
    }

    /// The phase after this one in this spec's workflow.
    public var nextPhase: KiroSpecPhase? {
        guard let index = kind.order.firstIndex(of: phase), index + 1 < kind.order.count else { return nil }
        return kind.order[index + 1]
    }

    /// Phases already reached, this one included.
    public var reachedPhases: [KiroSpecPhase] {
        guard let index = kind.order.firstIndex(of: phase) else { return [phase] }
        return Array(kind.order[...index])
    }

    /// The title of the phase's document as Kiro names it ("Bug analysis" for a Bugfix spec).
    public func title(_ phase: KiroSpecPhase) -> String {
        if phase == .requirements, kind == .bugfix { return "Bug analysis" }
        return phase.title
    }
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
    public static let documents = ["requirements.md", "bugfix.md", "design.md", "tasks.md"]

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
    /// written; earlier documents stay editable so they can be revised, as Kiro allows. Quick Spec
    /// has no gates between documents, so all three can be written before building.
    /// `kind` is the workflow picked for a chat that has no spec yet.
    public static func gateRefusal(path rawPath: String, state: KiroSpecState?, kind: KiroSpecKind = .requirementsFirst) -> String? {
        let path = RepoWorkspace.normalize(rawPath)
        guard let state else {
            let first = KiroSpecState(slug: "x", phase: kind.firstPhase, kind: kind)
            if let slug = slug(fromPath: path) {
                let probe = KiroSpecState(slug: slug, phase: kind.firstPhase, kind: kind)
                let allowed: [String] = kind.hasGates
                    ? [probe.path(kind.firstPhase)].compactMap { $0 }
                    : [.requirements, .design, .tasks].compactMap { probe.path($0) }
                if allowed.contains(path) { return nil }
            }
            let file = first.path(kind.firstPhase).map { ($0 as NSString).lastPathComponent } ?? "requirements.md"
            return "Spec mode (\(kind.title)): no spec has been started in this chat yet, so the only file that can be written is `.kiro/specs/<feature-name>/\(file)` (kebab-case feature name)\(kind.hasGates ? "" : ", then `design.md` and `tasks.md`"). Write it first\(kind.hasGates ? " and ask the person to approve it" : "")."
        }
        if state.phase == .implementation { return nil }
        let phases: [KiroSpecPhase] = state.kind.hasGates ? state.reachedPhases : [.requirements, .design, .tasks]
        let allowed = phases.compactMap { state.path($0) }
        if allowed.contains(path) { return nil }
        let waiting = state.title(state.phase).lowercased()
        return "Spec mode: the \(waiting) for `\(state.slug)` haven't been approved yet, so only \(allowed.map { "`\($0)`" }.joined(separator: ", ")) can be written now. Finish `\(state.path(state.phase) ?? state.folder)`, then ask the person to approve it before going further."
    }

    /// Tools that run commands. Owner, 11 November 2026: "Block running commands during the
    /// requirements and design phases, not just file edits."
    public static let commandTools: Set<String> = ["run_command", "computer_task", "run_shell", "sync_staged_to_computer", "dispatch_workflow"]

    /// Whether a command may run now. nil = allowed. Commands wait while requirements or design
    /// are being written (and before any spec exists); from the tasks phase on they run.
    public static func commandRefusal(state: KiroSpecState?, kind: KiroSpecKind = .requirementsFirst) -> String? {
        let phase = state?.phase ?? kind.firstPhase
        guard phase == .requirements || phase == .design else { return nil }
        let title = state?.title(phase) ?? KiroSpecState(slug: "x", phase: phase, kind: kind).title(phase)
        return "Spec mode: commands don't run during the \(title.lowercased()) phase. Research with read_file, search_code and list_files, write the spec document, and ask the person to approve it; commands can run once the spec reaches its tasks."
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
        guard isApproval(message) else { return state }
        return approved(state, currentDocumentExists: currentDocumentExists)
    }

    /// The approval itself, shared by a chat reply and the approve button: one phase on, once the
    /// current phase's document exists.
    public static func approved(_ state: KiroSpecState, currentDocumentExists: Bool) -> KiroSpecState {
        guard state.phase != .implementation, currentDocumentExists, let next = state.nextPhase else { return state }
        var advanced = state
        advanced.phase = next
        return advanced
    }

    /// The approve button's label, like Kiro's floating review button: "Approve requirements → design".
    /// nil when nothing waits for approval (building, or Quick Spec, which has no gates).
    public static func approvalButtonTitle(_ state: KiroSpecState) -> String? {
        guard state.kind.hasGates, state.phase != .implementation, let next = state.nextPhase else { return nil }
        let to = next == .implementation ? "build" : state.title(next).lowercased()
        return "Approve \(state.title(state.phase).lowercased()) → \(to)"
    }

    /// The chat message the approve button sends, so the approval is in the conversation too.
    public static func approvalMessage(_ state: KiroSpecState) -> String {
        guard let next = state.nextPhase else { return "Approved." }
        let to = next == .implementation ? "start on the tasks" : "move on to the \(state.title(next).lowercased())"
        return "Approved: the \(state.title(state.phase).lowercased()) look good. Please \(to)."
    }

    /// Quick Spec has no gates: once its `tasks.md` exists it lands on the task list, ready to build.
    public static func afterQuickTurn(_ state: KiroSpecState, hasTasks: Bool) -> KiroSpecState {
        guard state.kind == .quick, state.phase != .implementation else { return state }
        var next = state
        next.phase = hasTasks ? .implementation : state.phase
        return next
    }

    /// After a turn: a chat with no spec yet picks one up from the requirements it just wrote.
    public static func discovered(stagedPaths: [String], current: KiroSpecState?, kind: KiroSpecKind = .requirementsFirst) -> KiroSpecState? {
        if let current { return current }
        let firstFile = KiroSpecState(slug: "x", phase: kind.firstPhase, kind: kind).path(kind.firstPhase).map { "/" + ($0 as NSString).lastPathComponent } ?? "/requirements.md"
        let slugs = stagedPaths.compactMap { path -> String? in
            guard let slug = slug(fromPath: path) else { return nil }
            let normalized = RepoWorkspace.normalize(path)
            if normalized.hasSuffix(firstFile) { return slug }
            // Quick Spec writes all three documents in one go; any of them starts the spec.
            if kind == .quick, !normalized.hasSuffix("/bugfix.md") { return slug }
            return nil
        }
        return slugs.sorted().first.map { KiroSpecState(slug: $0, phase: kind.firstPhase, kind: kind) }
    }

    /// An existing spec (already in the repo, so already reviewed there) picked up by `#spec:<name>`:
    /// it resumes at its last document, or builds when `tasks.md` exists.
    public static func resume(slug: String, hasRequirements: Bool, hasDesign: Bool, hasTasks: Bool, hasBugfix: Bool = false) -> KiroSpecState {
        let kind: KiroSpecKind = hasBugfix && !hasRequirements ? .bugfix : (hasDesign && !hasRequirements && !hasBugfix ? .designFirst : .requirementsFirst)
        if hasTasks { return KiroSpecState(slug: slug, phase: .implementation, kind: kind) }
        if kind == .designFirst { return KiroSpecState(slug: slug, phase: .design, kind: kind) }
        if hasDesign { return KiroSpecState(slug: slug, phase: .design, kind: kind) }
        return KiroSpecState(slug: slug, phase: .requirements, kind: kind)
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

    static let requirementsFormat = """
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
    """

    static let bugfixFormat = """
    # Bugfix Document
    ## Introduction
    (the bug, how to reproduce it, and any code that must not change)
    ## Current Behavior (Defect)
    1. WHEN <condition> THEN the system <incorrect behavior>
    ## Expected Behavior (Correct)
    1. WHEN <condition> THEN the system SHALL <correct behavior>
    ## Unchanged Behavior (Regression Prevention)
    1. WHEN <condition> THEN the system SHALL CONTINUE TO <existing behavior>
    """

    static let designFormat = "Overview, Architecture, Components and Interfaces, Data Models, Error Handling, Testing Strategy (Mermaid diagrams where they help)"
    static let bugfixDesignFormat = "Root Cause Analysis, Fix Approach, and the properties to test: the current code shows the bug, the fixed code behaves correctly, and the unchanged behaviour keeps working"

    static let tasksFormat = """
    # Implementation Plan
    - [ ] 1. <coding task>
      - <details>
      - _Requirements: 1.1, 2.3_
    - [ ] 2. <next task>
      - [ ] 2.1 <sub-task>
    Only coding tasks (writing, changing or testing code), each small, building on the previous ones and referring to the requirements it covers.
    """

    /// The Spec-mode section of the system prompt for this phase. `kind` is the workflow picked
    /// for a chat with no spec yet.
    public static func instructions(state: KiroSpecState?, existingSpecs: [String] = [], kind: KiroSpecKind = .requirementsFirst) -> String {
        let workflow = state?.kind ?? kind
        var lines = ["", "", "## Spec mode (this chat, \(workflow.title))",
                     "The person chose Spec for this chat, the way Kiro's Spec mode works. A spec is three Markdown files in the repo under `.kiro/specs/<feature-name>/`: \(workflow == .bugfix ? "`bugfix.md`" : "`requirements.md`"), `design.md` and `tasks.md`. Workflow: \(workflow.title) (\(workflow.explanation)). " + (workflow.hasGates
                        ? "Each document is shown to the person and approved before the next is written; the app only lets you write the current document until then, and commands don't run until the spec reaches its tasks."
                        : "Quick Spec: first ask the person a few clarifying questions up front (scope, constraints, edge cases) unless the conversation already answers them, then write all three documents in one pass with no approval stops, and land on the task list.") + " Plain questions are answered directly and need no spec. Stage the documents with the file tools and save them with `save_changes` so they are in the repo for review."]
        if !existingSpecs.isEmpty {
            lines.append("Specs already in this repo: " + existingSpecs.prefix(40).map { "`\($0)`" }.joined(separator: ", ") + ". Read one with `load_spec` when it is relevant.")
        }
        guard let state else {
            switch workflow {
            case .requirementsFirst:
                lines.append("No spec has been started in this chat. For a request to build or change something: choose a short kebab-case feature name and write `.kiro/specs/<feature-name>/requirements.md` only. Format:\n" + requirementsFormat + "\nUse what the conversation has already said. Then stop and ask: \"Do the requirements look good? If so, we can move on to the design.\"")
            case .designFirst:
                lines.append("No spec has been started in this chat. Design-First: choose a short kebab-case feature name and write `.kiro/specs/<feature-name>/design.md` only, starting from the architecture, pseudocode or constraints the person gave: " + designFormat + ". Research the code first. Then stop and ask: \"Does the design look good? If so, we can derive the requirements from it.\"")
            case .bugfix:
                lines.append("No spec has been started in this chat. Bug Fix: choose a short kebab-case name for the bug and write `.kiro/specs/<bug-name>/bugfix.md` only. Format:\n" + bugfixFormat + "\nAsk for reproduction steps if they are missing. Then stop and ask: \"Does the bug analysis look right? If so, we can move on to the fix design.\"")
            case .quick:
                lines.append("No spec has been started in this chat. Quick Spec: ask your clarifying questions first if anything important is unknown. Once answered, choose a kebab-case feature name and write `.kiro/specs/<feature-name>/requirements.md`, then `design.md`, then `tasks.md`, all in this reply. Requirements format:\n" + requirementsFormat + "\nDesign sections: " + designFormat + ".\nTasks format:\n" + tasksFormat + "\nThen say the task list is ready and ask which task to start.")
            }
            return lines.joined(separator: "\n")
        }
        lines.append("This chat's spec: `\(state.folder)`. Its documents are included below under \"Repository text\" when they exist; call `load_spec` (name `\(state.slug)`) if you need them again.")
        if state.kind == .quick, state.phase != .implementation {
            lines.append("Quick Spec, not finished: write whichever of `requirements.md`, `design.md` and `tasks.md` are missing, in that order, with no approval stops. Requirements format:\n" + requirementsFormat + "\nDesign sections: " + designFormat + ".\nTasks format:\n" + tasksFormat)
            return lines.joined(separator: "\n")
        }
        let next = state.nextPhase.map { $0 == .implementation ? "the implementation plan" : "the " + state.title($0).lowercased() } ?? "building"
        switch state.phase {
        case .requirements where state.kind == .bugfix:
            lines.append("Phase: bug analysis, waiting for approval. Revise `\(state.path(.requirements)!)` as the person asks, in this format:\n" + bugfixFormat + "\nThen ask again whether it looks right. Do not write the fix design yet.")
        case .requirements where state.kind == .designFirst:
            lines.append("Phase: requirements. The design is approved. Derive feasible requirements from `\(state.path(.design)!)` and write (or revise) `\(state.path(.requirements)!)`:\n" + requirementsFormat + "\nThen stop and ask: \"Do the requirements look good? If so, we can move on to the implementation plan.\"")
        case .requirements:
            lines.append("Phase: requirements, waiting for approval. Revise `\(state.path(.requirements)!)` as the person asks (EARS acceptance criteria), then ask again whether they look good. Do not write the design yet.")
        case .design where state.kind == .designFirst:
            lines.append("Phase: design, waiting for approval. Revise `\(state.path(.design)!)` as the person asks (" + designFormat + "), then ask again whether it looks good. Do not write the requirements yet.")
        case .design:
            let sections = state.kind == .bugfix ? bugfixDesignFormat : designFormat
            lines.append("Phase: design. The \(state.title(.requirements).lowercased()) is approved. Write (or revise) `\(state.path(.design)!)`: \(sections). Research the code first. Then stop and ask: \"Does the design look good? If so, we can move on to \(next).\"")
        case .tasks:
            let extra = state.kind == .bugfix ? " Include tests that show the bug, show it fixed, and show the unchanged behaviour still works." : ""
            lines.append("Phase: tasks. The earlier documents are approved. Write (or revise) `\(state.path(.tasks)!)`:\n" + tasksFormat + extra + "\nThen stop and ask: \"Do the tasks look good?\"")
        case .implementation:
            lines.append("""
            Phase: building. The tasks are approved. When the person asks to run a task, do exactly that task (and its sub-tasks); with no task named, do the next unchecked one. Run all tasks only when asked. Check each finished task off by changing `- [ ]` to `- [x]` in `\(state.path(.tasks)!)`, verify the work, save, then stop and say what was done and which task is next. If you must depart from the design, say so and update the spec.
            """)
        }
        return lines.joined(separator: "\n")
    }
}

/// Wraps the file-changing tools so Spec mode's approval gates are enforced in code, not just asked for.
/// Commands (run_command and the like) are gated too, during the requirements and design phases.
public struct KiroSpecGatedTool: AgentTool {
    let inner: any AgentTool
    let state: @Sendable () -> KiroSpecState?
    let kind: KiroSpecKind

    public init(_ inner: any AgentTool, kind: KiroSpecKind = .requirementsFirst, state: @escaping @Sendable () -> KiroSpecState?) {
        self.inner = inner
        self.state = state
        self.kind = kind
    }

    public static func wrap(_ tools: [any AgentTool], kind: KiroSpecKind = .requirementsFirst, state: @escaping @Sendable () -> KiroSpecState?) -> [any AgentTool] {
        tools.map { KiroSpecs.gatedTools.contains($0.name) || KiroSpecs.commandTools.contains($0.name) ? KiroSpecGatedTool($0, kind: kind, state: state) : $0 }
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
        if KiroSpecs.commandTools.contains(inner.name) {
            guard let reason = KiroSpecs.commandRefusal(state: state(), kind: kind) else { return nil }
            return ToolOutput(forModel: reason, summary: "Commands wait for the spec", detail: reason, isError: true)
        }
        let path = arguments["path"]?.stringValue ?? ""
        guard let reason = KiroSpecs.gateRefusal(path: path, state: state(), kind: kind) else { return nil }
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
        let base = KiroSpecs.folder + requested + "/"
        // A Bugfix spec has bugfix.md where a feature spec has requirements.md.
        let hasRequirements = await read(base + "requirements.md") != nil
        let hasBugfix = await read(base + "bugfix.md") != nil
        let first = !hasRequirements && hasBugfix ? "bugfix.md" : "requirements.md"
        for document in [first, "design.md", "tasks.md"] {
            let path = base + document
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
