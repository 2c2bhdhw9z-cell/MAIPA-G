import AgentCore
import Foundation

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
        step1.toolCalls = [search, read]

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

    static func sampleSummaries() -> [ChatSummary] {
        let titles: [(String, String?, Double)] = [
            ("How saving chats works", "2c2bhdhw9z-cell/MAIPA-G", -60),
            ("Plan the settings screen", "2c2bhdhw9z-cell/Continuum-", -3_000),
            ("Find the crash", "2c2bhdhw9z-cell/Continuum-", -9_000),
            ("Birthday message for Mom", nil, -90_000),
            ("Explain the GameCube cache", "2c2bhdhw9z-cell/Continuum-", -300_000),
            ("Ideas for the snes TAS tool", "2c2bhdhw9z-cell/snes-tas-studio", -900_000),
        ]
        return titles.map { title, repo, offset in
            var chat = Chat(title: title, repo: repo.flatMap(RepoRef.init(fullName:)).map { ChatRepo(ref: $0, branch: "main", defaultBranch: "main", isPrivate: false) })
            chat.messages = [.user(title)]
            chat.updatedAt = Date().addingTimeInterval(offset)
            return ChatSummary(chat)
        }
    }
}
