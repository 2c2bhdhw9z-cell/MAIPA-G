import AgentCore
import Foundation
import UIKit

/// For checking how the app looks without a phone. The build check launches the app in Apple's
/// iPhone simulator with `-preview <scene>` and takes a screenshot of each scene. A preview shows
/// made-up content, never touches the network or the Keychain, and saves nothing. Without the
/// launch argument (on a real phone, always) none of this runs.
enum PreviewScenes {
    static let scene: String? = {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-preview"), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }()

    static var isActive: Bool { scene != nil }

    /// A finished chat about a repo, with thinking, tools, Markdown, code and a table.
    static func sampleChat() -> Chat {
        var chat = Chat(title: "How saving chats works", repo: ChatRepo(ref: RepoRef(owner: "2c2bhdhw9z-cell", name: "MAIPA-G"), branch: "main", defaultBranch: "main", isPrivate: false))
        chat.createdAt = Date().addingTimeInterval(-600)
        chat.updatedAt = Date().addingTimeInterval(-60)

        var step1 = AssistantStep(startedAt: Date().addingTimeInterval(-58))
        step1.finishedAt = Date().addingTimeInterval(-52)
        step1.model = "anthropic/claude-sonnet-5.5"
        step1.reasoning = "The person wants to know where chats are saved. I'll find the sync code first, then read it."
        step1.text = "Let me find where that happens."
        var search = ToolCallRecord(id: "c1", name: "search_code", arguments: #"{"query":"MAIPA-G-data"}"#, summary: "Searched for “MAIPA-G-data” · 6 matches", status: .done)
        search.detail = "AgentCore/Sources/AgentCore/Store/DataRepoSync.swift\n  14: public static let repoName = \"MAIPA-G-data\""
        var read = ToolCallRecord(id: "c2", name: "read_file", arguments: #"{"path":"AgentCore/Sources/AgentCore/Store/DataRepoSync.swift"}"#, summary: "Read AgentCore/Sources/AgentCore/Store/DataRepoSync.swift", status: .done)
        read.detail = "     1\timport Foundation\n     2\t\n     3\t/// Mirrors MAIPA-G's saved data…"
        var command = ToolCallRecord(id: "c3", name: "run_shell", arguments: #"{"command":"swift test --package-path AgentCore"}"#, summary: "Command finished", status: .done)
        command.detail = "Exit code: 0\nAll checks passed."
        step1.toolCalls = [search, read, command]

        var step2 = AssistantStep(startedAt: Date().addingTimeInterval(-50))
        step2.finishedAt = Date().addingTimeInterval(-40)
        step2.model = "anthropic/claude-sonnet-5.5"
        step2.usage = Usage(promptTokens: 9_200, completionTokens: 410, cost: 0.0214)
        step2.text = """
        Your chats are saved in **two places**:

        1. On the phone, one file per chat.
        2. In your private repo `MAIPA-G-data` on GitHub, a few seconds after each change.

        When both have changed, the newer one wins:

        ```swift
        if theirs.updatedAt > mine.updatedAt {
            keep(theirs) // the other copy is newer
        }
        ```

        | Where | When |
        |:------|:-----|
        | Phone | Right away |
        | GitHub | After a few seconds |

        So deleting the app loses nothing. See [DataRepoSync.swift](https://github.com/2c2bhdhw9z-cell/MAIPA-G) for the details.
        """
        var turn = AssistantTurn(status: .done, steps: [step1, step2], routeLabel: "Auto · medium")
        turn.notices = []
        chat.messages = [
            ChatMessage(createdAt: Date().addingTimeInterval(-60), body: .user(UserMessage(text: "Where does MAIPA-G keep my chats?"))),
            ChatMessage(createdAt: Date().addingTimeInterval(-58), body: .assistant(turn)),
        ]
        return chat
    }

    static func pictureChat() -> Chat {
        var chat = Chat(title: "A picture for the launch page")
        var step = AssistantStep(); step.finishedAt = Date(); step.text = "I made the picture and saved it with this chat."; step.generatedImages = [sampleGeneratedImage()]
        chat.messages = [.user("Make a friendly MAIPA-G launch picture"), ChatMessage(body: .assistant(AssistantTurn(status: .done, steps: [step], routeLabel: "Image AI")))]
        return chat
    }

    /// A chat where the AI is waiting on numbered questions.
    static func questionChat() -> Chat {
        var chat = Chat(title: "Plan the settings screen")
        var step = AssistantStep()
        step.finishedAt = Date()
        step.model = "openai/gpt-6"
        step.text = "Happy to plan it. Two things first:"
        var ask = ToolCallRecord(id: "q1", name: AskUserTool.name, arguments: "{}", summary: "Asked you 2 questions", status: .waitingForUser)
        ask.questions = QuestionSet(questions: [
            .init(text: "Should every card start folded?", options: ["Yes, all folded", "Only the long ones", "No"]),
            .init(text: "Where should Appearance go?", options: ["At the top", "Under Look"]),
        ])
        step.toolCalls = [ask]
        chat.messages = [
            .user("Plan a better settings screen for Continuum"),
            ChatMessage(body: .assistant(AssistantTurn(status: .waitingForUser, steps: [step], routeLabel: "Auto · high"))),
        ]
        return chat
    }

    /// A reply still being written, with a tool running.
    static func workingChat() -> Chat {
        var chat = Chat(title: "Find the crash")
        var step = AssistantStep()
        step.model = "anthropic/claude-sonnet-5.5"
        step.reasoning = "Looking for where the app could crash on launch."
        step.finishedAt = Date()
        step.toolCalls = [
            ToolCallRecord(id: "w1", name: "search_code", arguments: "{}", summary: "Getting a copy of the repo to search · 23 MB", status: .running),
            ToolCallRecord(id: "w2", name: "list_files", arguments: "{}", summary: "Looked in native/ios", status: .done),
        ]
        chat.messages = [
            .user("Why does the app crash when I open a game?"),
            ChatMessage(body: .assistant(AssistantTurn(status: .running, steps: [step], routeLabel: "Auto · high"))),
        ]
        return chat
    }

    /// The moment just after sending: Spark and "Thinking…", nothing written yet.
    static func thinkingChat() -> Chat {
        var chat = Chat(title: "Birthday message for Mom")
        chat.messages = [
            .user("Write a short birthday message for my mom, something warm but not cheesy"),
            ChatMessage(body: .assistant(AssistantTurn(status: .running, steps: [AssistantStep()], routeLabel: "Auto · low"))),
        ]
        return chat
    }

    static func sampleJobs(needsYou: Bool) -> [JobRecord] {
        let repo = RepoRef(owner: "2c2bhdhw9z-cell", name: "MAIPA-G")
        var active = JobRecord(
            status: needsYou ? .needsApproval : .running,
            title: "Finish the settings screen",
            targetRepo: repo,
            targetRef: "main",
            defaultBranch: "main",
            steps: [
                JobStepRecord(title: "Read the project", detail: "Found the existing settings and tests", status: .done, startedAt: Date().addingTimeInterval(-300), finishedAt: Date().addingTimeInterval(-260)),
                JobStepRecord(title: "Update the app", detail: needsYou ? "Needs approval before changing the build setup" : "Editing SettingsScreen.swift", status: needsYou ? .waiting : .running, startedAt: Date().addingTimeInterval(-250)),
                JobStepRecord(title: "Check the work"),
            ],
            cumulativeCost: 0.18,
            workflowRunID: 123,
            workflowRunURL: "https://github.com/2c2bhdhw9z-cell/MAIPA-G/actions/runs/123",
            logsURL: "https://github.com/2c2bhdhw9z-cell/MAIPA-G/actions/runs/123"
        )
        if needsYou {
            active.questions = [JobQuestion(text: "Allow this command to change the repo's build setup?", options: ["Allow", "Don't allow"], isApproval: true)]
        }
        var done = JobRecord(status: .done, title: "Fix the launch crash", targetRepo: repo, targetRef: "main", defaultBranch: "main", cumulativeCost: 0.09)
        done.steps = [JobStepRecord(title: "Fix and test", detail: "All checks passed", status: .done, startedAt: Date().addingTimeInterval(-3_600), finishedAt: Date().addingTimeInterval(-3_200))]
        done.result = JobResult(summary: "Fixed the launch crash and checked the app.")
        return [active, done]
    }

    static let previewGroupID = UUID(uuidString: "00000000-0000-0000-0000-000000000041")!

    static func sampleMemories() -> [MemoryRecord] {
        let now = Date()
        return [
            MemoryRecord(text: "Keep explanations plain and short.", source: .user, createdAt: now.addingTimeInterval(-86_400)),
            MemoryRecord(text: "Continuum saves changes straight to master.", source: .star, createdAt: now.addingTimeInterval(-3_600)),
            MemoryRecord(text: "Check an IPA before calling an iPhone build done.", isEnabled: false, source: .ai, createdAt: now.addingTimeInterval(-600)),
        ]
    }

    static func sampleGroups() -> [ChatGroupRecord] {
        [ChatGroupRecord(id: previewGroupID, name: "MAIPA-G", order: 0)]
    }

    static func sampleSpecs() -> [SpecRecord] {
        let repo = RepoRef(owner: "2c2bhdhw9z-cell", name: "MAIPA-G")
        var spec = SpecRecord(repo: repo, slug: "memory-library", title: "Memory library", request: "Add memories", stage: .tasks)
        spec.requirements = "# Requirements\n\n1. Memories start empty.\n2. Enabled memories enter new chats."
        spec.design = "# Design\n\nUse the shared product store."
        spec.checkedDesign = spec.design + "\n\nChecked against every requirement."
        spec.tasksDocument = "- [ ] Add the shared record\n- [ ] Add the iPhone screens\n- [ ] Check persistence"
        spec.approvedStages = [.requirements, .design, .checkedDesign]
        return [spec]
    }

    static func sampleGeneratedImage() -> GeneratedImageResult {
        GeneratedImageResult(
            attachment: AttachmentReference(name: "maipa-g-picture.png", mimeType: "image/png", kind: .image, path: "media/preview/picture.png", bytes: 100),
            prompt: "A tiny friendly robot planning an app at a desk, soft violet light",
            model: "google/gemini-image", aspectRatio: "1:1", quality: "high", cost: 0.04
        )
    }

    static func pictureImage() -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 900, height: 900))
        return renderer.image { context in
            UIColor(red: 0.12, green: 0.08, blue: 0.22, alpha: 1).setFill(); context.fill(CGRect(x: 0, y: 0, width: 900, height: 900))
            let text = "✦\nMAIPA-G" as NSString
            text.draw(in: CGRect(x: 100, y: 260, width: 700, height: 380), withAttributes: [.font: UIFont.systemFont(ofSize: 105, weight: .bold), .foregroundColor: UIColor.white, .paragraphStyle: { let p = NSMutableParagraphStyle(); p.alignment = .center; return p }()])
        }
    }

    static func sampleSummaries() -> [ChatSummary] {
        let titles: [(String, String?, Double)] = [
            ("How saving chats works", "2c2bhdhw9z-cell/MAIPA-G", -60),
            ("Plan the settings screen", "2c2bhdhw9z-cell/Continuum-", -3_000),
            ("Find the crash", "2c2bhdhw9z-cell/Continuum-", -9_000),
            ("Birthday message for Mom", nil, -90_000),
            ("Explain the GameCube cache", "2c2bhdhw9z-cell/Continuum-", -300_000),
            ("Ideas for the snes TAS tool", "2c2bhdhw9z-cell/snes-tas-studio", -900_000),
        ]
        return titles.enumerated().map { index, value in
            let (title, repo, offset) = value
            var chat = Chat(title: title, repo: repo.flatMap(RepoRef.init(fullName:)).map { ChatRepo(ref: $0, branch: "main", defaultBranch: "main", isPrivate: false) }, groupID: index < 2 ? previewGroupID : nil)
            chat.messages = [.user(title)]
            chat.updatedAt = Date().addingTimeInterval(offset)
            return ChatSummary(chat)
        }
    }
}
