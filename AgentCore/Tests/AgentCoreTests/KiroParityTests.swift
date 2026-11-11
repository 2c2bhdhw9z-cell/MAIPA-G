import Foundation
import Testing
@testable import AgentCore

/// Kiro parity (owner, 11 November 2026): specs are three files in the repo, written in order with
/// an approval gate between each, steering follows Kiro's inclusion modes, and `#` references work.
@Suite("Kiro parity: specs, steering and # references")
struct KiroParityTests {
    // MARK: Spec files and phases

    @Test("Spec documents live in .kiro/specs/<feature>/ and only the three documents count")
    func specPaths() {
        #expect(KiroSpecs.slug(fromPath: ".kiro/specs/user-auth/requirements.md") == "user-auth")
        #expect(KiroSpecs.slug(fromPath: "/.kiro/specs/user-auth/tasks.md") == "user-auth")
        #expect(KiroSpecs.slug(fromPath: ".kiro/specs/user-auth/notes.md") == nil)
        #expect(KiroSpecs.slug(fromPath: ".kiro/specs/User Auth/design.md") == nil)
        #expect(KiroSpecs.slug(fromPath: "src/.kiro/specs/a/design.md") == nil)
        #expect(KiroSpecs.slugs(in: [".kiro/specs/b/design.md", ".kiro/specs/a/requirements.md", ".kiro/specs/a/tasks.md", "README.md"]) == ["a", "b"])
        let state = KiroSpecState(slug: "user-auth")
        #expect(state.path(.design) == ".kiro/specs/user-auth/design.md")
        #expect(state.path(.implementation) == nil)
    }

    @Test("Before any spec, only a requirements.md can be written")
    func gateBeforeSpec() {
        #expect(KiroSpecs.gateRefusal(path: ".kiro/specs/login/requirements.md", state: nil) == nil)
        #expect(KiroSpecs.gateRefusal(path: ".kiro/specs/login/design.md", state: nil) != nil)
        #expect(KiroSpecs.gateRefusal(path: "App/Login.swift", state: nil) != nil)
    }

    @Test("Each phase may write its own document and earlier ones, never code, until tasks are approved")
    func gatesPerPhase() {
        let requirements = KiroSpecState(slug: "login", phase: .requirements)
        #expect(KiroSpecs.gateRefusal(path: ".kiro/specs/login/requirements.md", state: requirements) == nil)
        #expect(KiroSpecs.gateRefusal(path: ".kiro/specs/login/design.md", state: requirements) != nil)

        let design = KiroSpecState(slug: "login", phase: .design)
        #expect(KiroSpecs.gateRefusal(path: ".kiro/specs/login/design.md", state: design) == nil)
        #expect(KiroSpecs.gateRefusal(path: ".kiro/specs/login/requirements.md", state: design) == nil)
        #expect(KiroSpecs.gateRefusal(path: ".kiro/specs/login/tasks.md", state: design) != nil)
        #expect(KiroSpecs.gateRefusal(path: ".kiro/specs/other/design.md", state: design) != nil)

        let tasks = KiroSpecState(slug: "login", phase: .tasks)
        #expect(KiroSpecs.gateRefusal(path: ".kiro/specs/login/tasks.md", state: tasks) == nil)
        #expect(KiroSpecs.gateRefusal(path: "App/Login.swift", state: tasks) != nil)

        let building = KiroSpecState(slug: "login", phase: .implementation)
        #expect(KiroSpecs.gateRefusal(path: "App/Login.swift", state: building) == nil)
    }

    @Test("Approval moves one phase on, only for a clear yes and only once the document exists")
    func approvalAdvances() {
        let requirements = KiroSpecState(slug: "login", phase: .requirements)
        #expect(KiroSpecs.afterMessage("Looks good, move on to the design", state: requirements, currentDocumentExists: true).phase == .design)
        #expect(KiroSpecs.afterMessage("yes", state: requirements, currentDocumentExists: false).phase == .requirements)
        #expect(KiroSpecs.afterMessage("Add a requirement for password reset", state: requirements, currentDocumentExists: true).phase == .requirements)
        #expect(KiroSpecs.afterMessage("Looks good but change 2.1", state: requirements, currentDocumentExists: true).phase == .requirements)
        #expect(KiroSpecs.afterMessage("Is it good?", state: requirements, currentDocumentExists: true).phase == .requirements)
        #expect(KiroSpecs.afterMessage("lgtm", state: KiroSpecState(slug: "login", phase: .design), currentDocumentExists: true).phase == .tasks)
        #expect(KiroSpecs.afterMessage("Approved 👍", state: KiroSpecState(slug: "login", phase: .tasks), currentDocumentExists: true).phase == .implementation)
        #expect(KiroSpecs.afterMessage("go", state: KiroSpecState(slug: "login", phase: .implementation), currentDocumentExists: true).phase == .implementation)
        #expect(!KiroSpecs.isApproval("Not yet, the design is missing caching"))
        #expect(!KiroSpecs.isApproval(""))
    }

    @Test("A chat picks up its spec from the requirements it wrote; an existing spec resumes where it is")
    func discoveryAndResume() {
        #expect(KiroSpecs.discovered(stagedPaths: ["README.md", ".kiro/specs/login/requirements.md"], current: nil) == KiroSpecState(slug: "login", phase: .requirements))
        #expect(KiroSpecs.discovered(stagedPaths: [".kiro/specs/login/design.md"], current: nil) == nil)
        let current = KiroSpecState(slug: "a", phase: .design)
        #expect(KiroSpecs.discovered(stagedPaths: [".kiro/specs/b/requirements.md"], current: current) == current)
        #expect(KiroSpecs.resume(slug: "x", hasRequirements: true, hasDesign: true, hasTasks: true).phase == .implementation)
        #expect(KiroSpecs.resume(slug: "x", hasRequirements: true, hasDesign: true, hasTasks: false).phase == .design)
        #expect(KiroSpecs.resume(slug: "x", hasRequirements: true, hasDesign: false, hasTasks: false).phase == .requirements)
    }

    @Test("tasks.md checkboxes are read with their numbers and nesting")
    func tasksParse() {
        let doc = """
        # Implementation Plan
        - [x] 1. Set up the data model
          - Create the struct
          - _Requirements: 1.1_
        - [ ] 2. Build the form
          - [ ] 2.1 Add fields
          - [X] 2.2 Validate input
        * [ ] Write docs
        - [?] not a task
        """
        let tasks = KiroSpecs.tasks(in: doc)
        #expect(tasks.map(\.number) == ["1", "2", "2.1", "2.2", ""])
        #expect(tasks.map(\.isDone) == [true, false, false, true, false])
        #expect(tasks[0].title == "Set up the data model")
        #expect(tasks[2].depth == 1)
        #expect(tasks[4].title == "Write docs")
    }

    @Test("Spec-mode instructions name the current document and the EARS format")
    func instructions() {
        let start = KiroSpecs.instructions(state: nil, existingSpecs: ["checkout"])
        #expect(start.contains("requirements.md"))
        #expect(start.contains("THE SYSTEM SHALL"))
        #expect(start.contains("`checkout`"))
        #expect(KiroSpecs.instructions(state: KiroSpecState(slug: "login", phase: .design)).contains(".kiro/specs/login/design.md"))
        #expect(KiroSpecs.instructions(state: KiroSpecState(slug: "login", phase: .implementation)).contains("- [x]"))
    }

    // MARK: Gated tools

    struct WriteRecorder: AgentTool {
        let name: String
        let log: Log
        final class Log: @unchecked Sendable { var paths: [String] = [] }
        var spec: ToolSpec { ToolSpec(name: name, description: "", parameters: ["type": "object"]) }
        func runningSummary(for arguments: JSONValue) -> String { "" }
        func run(arguments: JSONValue, progress: @escaping @Sendable (String) -> Void) async throws -> ToolOutput {
            log.paths.append(arguments["path"]?.stringValue ?? "")
            return ToolOutput(forModel: "ok", summary: "ok")
        }
    }

    @Test("The gate refuses writes in code and lets reads and allowed writes through")
    func gatedTool() async throws {
        let log = WriteRecorder.Log()
        let tools: [any AgentTool] = [WriteRecorder(name: "edit_file", log: log), WriteRecorder(name: "read_file", log: log)]
        let wrapped = KiroSpecGatedTool.wrap(tools, state: { KiroSpecState(slug: "login", phase: .requirements) })
        #expect(wrapped[0] is KiroSpecGatedTool)
        #expect(!(wrapped[1] is KiroSpecGatedTool))
        let refused = try await wrapped[0].run(arguments: ["path": "App/Login.swift"], progress: { _ in })
        #expect(refused.isError)
        #expect(refused.forModel.contains("haven't been approved"))
        let allowed = try await wrapped[0].run(arguments: ["path": ".kiro/specs/login/requirements.md"], progress: { _ in })
        #expect(!allowed.isError)
        _ = try await wrapped[1].run(arguments: ["path": "App/Login.swift"], progress: { _ in })
        #expect(log.paths == [".kiro/specs/login/requirements.md", "App/Login.swift"])
    }

    @Test("load_spec reads all three documents, lists specs, and is outside content")
    func loadSpec() async throws {
        let files = [
            ".kiro/specs/login/requirements.md": "# Requirements Document\nWHEN x THEN THE SYSTEM SHALL y",
            ".kiro/specs/login/design.md": "# Design",
        ]
        let tool = LoadSpecTool(read: { files[$0] }, list: { Array(files.keys) + ["README.md"] })
        #expect(tool.bringsOutsideContent)
        let listed = try await tool.run(arguments: [:], progress: { _ in })
        #expect(listed.forModel.contains("login"))
        let read = try await tool.run(arguments: ["name": "login"], progress: { _ in })
        #expect(read.forModel.contains("THE SYSTEM SHALL"))
        #expect(read.forModel.contains("# Design"))
        #expect(read.forModel.contains("tasks.md --- (not written yet)"))
        let missing = try await tool.run(arguments: ["name": "nope"], progress: { _ in })
        #expect(missing.forModel.contains("No spec named nope"))
    }

    @Test("A chat's spec is saved with the chat, and older chats without one still load")
    func chatStoresSpec() throws {
        var chat = Chat()
        chat.kiroSpec = KiroSpecState(slug: "login", phase: .tasks)
        let decoded = try JSONDecoder().decode(Chat.self, from: JSONEncoder().encode(chat))
        #expect(decoded.kiroSpec == KiroSpecState(slug: "login", phase: .tasks))
        var plain = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Chat())) as! [String: Any]
        plain.removeValue(forKey: "kiroSpec")
        let old = try JSONDecoder().decode(Chat.self, from: JSONSerialization.data(withJSONObject: plain))
        #expect(old.kiroSpec == nil)
    }

    // MARK: Steering

    static let always = RepoRuleDocument(path: ".kiro/steering/tech.md", text: "Use Swift 6.")
    static let alwaysExplicit = RepoRuleDocument(path: ".kiro/steering/product.md", text: "---\ninclusion: always\n---\nAn iPhone app.")
    static let swiftOnly = RepoRuleDocument(path: ".kiro/steering/swift.md", text: "---\ninclusion: fileMatch\nfileMatchPattern: [\"**/*.swift\", \"Package.swift\"]\n---\nSwift rules.")
    static let manual = RepoRuleDocument(path: ".kiro/steering/troubleshooting.md", text: "---\ninclusion: manual\n---\nSteps.")
    static let auto = RepoRuleDocument(path: ".kiro/steering/api.md", text: "---\ninclusion: auto\nname: api-design\ndescription: REST API conventions\n---\nAPI rules.")
    static let blankFirst = RepoRuleDocument(path: ".kiro/steering/late.md", text: "\n---\ninclusion: manual\n---\nNot front matter.")
    static let agents = RepoRuleDocument(path: "AGENTS.md", text: "---\ninclusion: manual\n---\nAGENTS.md ignores inclusion modes.")

    @Test("Inclusion modes come from front matter at the very top of a steering file")
    func inclusionModes() {
        #expect(Self.always.inclusion == .always)
        #expect(Self.alwaysExplicit.inclusion == .always)
        #expect(Self.swiftOnly.inclusion == .fileMatch(["**/*.swift", "Package.swift"]))
        #expect(Self.manual.inclusion == .manual)
        #expect(Self.auto.inclusion == .auto(name: "api-design", description: "REST API conventions"))
        #expect(Self.blankFirst.inclusion == .always)
        #expect(Self.agents.inclusion == .always)
        #expect(RepoRuleDocument(path: ".kiro/steering/one.md", text: "---\ninclusion: fileMatch\nfileMatchPattern: \"components/**/*.tsx\"\n---\n").inclusion == .fileMatch(["components/**/*.tsx"]))
        #expect(Self.swiftOnly.matchesFile("App/Sources/Main.swift"))
        #expect(!Self.swiftOnly.matchesFile("README.md"))
        #expect(Self.manual.steeringName == "troubleshooting")
    }

    @Test("Applicable steering: always ones, fileMatch for paths in play, manual and auto when named")
    func applicableSteering() {
        let docs = [Self.always, Self.swiftOnly, Self.manual, Self.auto, Self.agents]
        #expect(KiroSteering.applicable(docs, paths: [], referencedNames: []).map(\.path) == [".kiro/steering/tech.md", "AGENTS.md"])
        #expect(KiroSteering.applicable(docs, paths: ["App/A.swift"], referencedNames: []).map(\.path).contains(".kiro/steering/swift.md"))
        let named = KiroSteering.applicable(docs, paths: [], referencedNames: ["troubleshooting", "api-design"]).map(\.path)
        #expect(named.contains(".kiro/steering/troubleshooting.md"))
        #expect(named.contains(".kiro/steering/api.md"))
    }

    @Test("load_repo_rules honours inclusion modes: no manual steering unless named, fileMatch by path")
    func loadRulesByInclusion() async throws {
        let tool = LoadRepoRulesTool(documents: [Self.always, Self.swiftOnly, Self.manual, Self.auto])
        let general = try await tool.run(arguments: [:], progress: { _ in }).forModel
        #expect(general.contains("Use Swift 6."))
        #expect(!general.contains("Steps."))
        #expect(!general.contains("Swift rules."))
        let forSwift = try await tool.run(arguments: ["path": "App/Main.swift"], progress: { _ in }).forModel
        #expect(forSwift.contains("Swift rules."))
        #expect(forSwift.contains("Use Swift 6."))
        let named = try await tool.run(arguments: ["name": "#troubleshooting"], progress: { _ in }).forModel
        #expect(named.contains("Steps."))
        #expect(!named.contains("Use Swift 6."))
        let byAutoName = try await tool.run(arguments: ["name": "api-design"], progress: { _ in }).forModel
        #expect(byAutoName.contains("API rules."))
        let none = try await tool.run(arguments: ["name": "nothing"], progress: { _ in }).forModel
        #expect(none.contains("No steering file named nothing"))
    }

    @Test("The system prompt lists steering with when each applies, without inlining its text")
    func promptListsInclusion() {
        let repo = SystemPrompt.RepoContext(ref: RepoRef(owner: "o", name: "r"), branch: "main", commit: String(repeating: "a", count: 40), isPrivate: true, summary: nil, ruleDocuments: [Self.manual, Self.swiftOnly])
        let prompt = SystemPrompt.make(userLogin: nil, repo: repo)
        #expect(prompt.contains("only when the person references #troubleshooting"))
        #expect(prompt.contains("when working on **/*.swift"))
        #expect(!prompt.contains("Steps."))
    }

    // MARK: # references

    @Test("Kiro's # context providers are recognised in a message")
    func references() {
        let refs = KiroContextReferences.parse("#spec:user-auth implement task 2.3 using #steering:api-standards.md and #auth.ts, see #components/ #git diff #codebase #terminal #url:https://example.com/docs #troubleshooting")
        #expect(refs.specs == ["user-auth"])
        #expect(refs.steering == ["api-standards", "troubleshooting"])
        #expect(refs.files == ["auth.ts"])
        #expect(refs.folders == ["components"])
        #expect(refs.gitDiff)
        #expect(refs.codebase)
        #expect(refs.urls == ["https://example.com/docs"])
        #expect(refs.unavailable == ["#terminal"])
        #expect(refs.promptSection.contains("load_spec"))
        #expect(KiroContextReferences.parse("Issue #42 and a C# question").isEmpty)
        #expect(KiroContextReferences.parse("plain message").promptSection.isEmpty)
    }
}
