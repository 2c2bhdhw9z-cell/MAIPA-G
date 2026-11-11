import Foundation
import Testing
@testable import AgentCore

/// Owner, 11 November 2026: "You don't ask to run commands." Tools just run; only something that
/// can't be undone at all (destroying the chat computer) still asks.
@Suite("Tools just run")
struct AutoApproveTests {
    struct DestroyTool: AgentTool {
        let counter: ApprovalCounter
        let name = "destroy_sprite"
        var spec: ToolSpec { ToolSpec(name: name, description: "Destroy", parameters: ["type": "object"]) }
        func runningSummary(for arguments: JSONValue) -> String { "Destroying…" }
        func approvalRequest(for arguments: JSONValue) async -> ToolApprovalRequest? { ToolApprovalRequest(question: "Destroy the machine?") }
        func alwaysAsks(for arguments: JSONValue) async -> Bool { true }
        func run(arguments: JSONValue, progress: @escaping @Sendable (String) -> Void) async throws -> ToolOutput {
            await counter.increment()
            return ToolOutput(forModel: "gone", summary: "Destroyed")
        }
    }

    static func run(_ tool: any AgentTool, name: String) async -> AssistantTurn? {
        let transport = ScriptedTransport([
            .events([AgentLoopTests.toolCall(id: "c1", name: name, arguments: "{}"), AgentLoopTests.toolsDone]),
            .events([AgentLoopTests.text("Done."), AgentLoopTests.done]),
        ])
        let environment = AgentEnvironment(
            openRouter: OpenRouterClient(transport: transport, apiKey: "sk-test"),
            freeRoute: { ModelRouter.route(choice: .free, difficulty: .normal, thinking: .medium, account: AccountState(), catalogue: [:]) },
            onOutOfCredits: {}
        )
        var last: AssistantTurn?
        let input = AgentTurnInput(chat: AgentLoopTests.newChat("go"), route: AgentLoopTests.route(), systemPrompt: "system", tools: [tool], autoApprove: true)
        for await event in AgentLoop.run(input, environment: environment) {
            if case .updated(let turn, _) = event { last = turn }
        }
        return last
    }

    @Test("A tool that would have asked just runs")
    func runsWithoutAsking() async throws {
        let counter = ApprovalCounter()
        let turn = try #require(await Self.run(ApprovalTool(counter: counter), name: "delete_file"))
        #expect(turn.status == .done)
        #expect(await counter.runs == 1)
    }

    @Test("Destroying the computer still asks")
    func irreversibleStillAsks() async throws {
        let counter = ApprovalCounter()
        let turn = try #require(await Self.run(DestroyTool(counter: counter), name: "destroy_sprite"))
        #expect(turn.status == .waitingForUser)
        #expect(await counter.runs == 0)
        #expect(ConnectorActionPolicy.isIrreversible("destroy_sprite"))
        #expect(ConnectorActionPolicy.isIrreversible("delete_repository"))
        #expect(!ConnectorActionPolicy.isIrreversible("file_delete"))
        #expect(!ConnectorActionPolicy.isIrreversible("exec"))
    }
}

@Suite("Picture replies end with the picture")
struct EndAfterToolsTests {
    struct PictureTool: AgentTool {
        let name = "generate_image"
        var spec: ToolSpec { ToolSpec(name: name, description: "Picture", parameters: ["type": "object"]) }
        func runningSummary(for arguments: JSONValue) -> String { "Generating a picture…" }
        func run(arguments: JSONValue, progress: @escaping @Sendable (String) -> Void) async throws -> ToolOutput {
            ToolOutput(forModel: "made", summary: "Generated a picture")
        }
    }

    @Test("After the picture tool works, no second model call is made")
    func endsAfterThePicture() async throws {
        let transport = ScriptedTransport([
            .events([AgentLoopTests.toolCall(id: "p1", name: "generate_image", arguments: "{}"), AgentLoopTests.toolsDone]),
            .events([AgentLoopTests.text("Here it is."), AgentLoopTests.done]),
        ])
        let environment = AgentEnvironment(
            openRouter: OpenRouterClient(transport: transport, apiKey: "sk-test"),
            freeRoute: { ModelRouter.route(choice: .free, difficulty: .normal, thinking: .medium, account: AccountState(), catalogue: [:]) },
            onOutOfCredits: {}
        )
        var input = AgentTurnInput(chat: AgentLoopTests.newChat("make it blue"), route: AgentLoopTests.route(), systemPrompt: "system", tools: [PictureTool()], autoApprove: true)
        input.endAfterTools = ["generate_image"]
        var last: AssistantTurn?
        for await event in AgentLoop.run(input, environment: environment) {
            if case .updated(let turn, _) = event { last = turn }
        }
        #expect(last?.status == .done)
        #expect(transport.requestCount == 1)
        #expect(last?.steps.last?.text == "Generated a picture.")
    }
}
