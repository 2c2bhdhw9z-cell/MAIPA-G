import Foundation
import Testing
@testable import AgentCore

@Suite("Build 81 — Kiro Live Sub-Agent Cards, Exhaustive Context Gathering, & Crash Safety")
struct Build81Tests {
    private struct SimulatedSubagentFailure: Error, CustomStringConvertible {
        var description: String { "Simulated provider stream drop" }
    }

    private final class LiveUpdateRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var snapshots: [ToolLiveUpdate] = []

        func record(_ update: ToolLiveUpdate) {
            lock.lock()
            defer { lock.unlock() }
            snapshots.append(update)
        }

        var all: [ToolLiveUpdate] {
            lock.lock()
            defer { lock.unlock() }
            return snapshots
        }
    }

    @Test("AgentHelperCoordinator streams live sub-agent cards, isolates sibling errors, and cancels without crashing")
    func coordinatorStreamsLiveCardsIsolatesFailuresAndCancelsCleanly() async throws {
        var lead = try #require(BuiltInAgents.named("coder"))
        lead.maximumHelpers = 8
        let definitions = BuiltInAgents.kiroSubagents

        // 1. Parallel completion + sibling failure isolation (zero values[index]! crash)
        let recorder = LiveUpdateRecorder()
        let coordinator = AgentHelperCoordinator(
            lead: lead,
            definitions: definitions,
            context: "Read the whole codebase thoroughly.",
            spendLimit: nil
        ) { invocation in
            if invocation.task.contains("FAIL_BRANCH") {
                invocation.onLiveProgress?(AgentLiveProgress(
                    model: "particle-ai/particle-1",
                    toolCallCount: 2,
                    latestActivity: "Reading Broken.swift…",
                    toolSummaries: ["Looked in Sources", "Reading Broken.swift…"]
                ))
                throw SimulatedSubagentFailure()
            }
            invocation.onLiveProgress?(AgentLiveProgress(
                model: "particle-ai/particle-1",
                toolCallCount: 3,
                latestActivity: "Read AgentLoop.swift · lines 1–850",
                toolSummaries: [
                    "Looked in AgentCore/Sources",
                    "Read SystemPrompt.swift",
                    "Read AgentLoop.swift · lines 1–850",
                ],
                liveThought: "Checking every line of AgentLoop.swift…",
                partialOutput: "Verified lines 1–850."
            ))
            try await Task.sleep(nanoseconds: 15_000_000)
            return AgentExecutionResult(
                output: "Complete line-by-line report for AgentCore.",
                model: "particle-ai/particle-1",
                cost: 0.02,
                toolCallCount: 3,
                toolSummaries: [
                    "Looked in AgentCore/Sources",
                    "Read SystemPrompt.swift",
                    "Read AgentLoop.swift · lines 1–850",
                ],
                status: "completed"
            )
        }

        let tool = LaunchHelpersTool(lead: lead, definitions: definitions, coordinator: coordinator)
        let args: JSONValue = [
            "helpers": [
                ["agent_id": "context-gatherer", "task": "Read AgentCore thoroughly from line 1 to EOF."],
                ["agent_id": "semantic-reviewer", "task": "FAIL_BRANCH audit edge cases."],
            ],
        ]
        let initial = try #require(tool.initialSubagents(for: args, callID: "call-1"))
        #expect(initial.count == 2)
        #expect(initial[0].name == "Context Gatherer")
        #expect(initial[0].task == "Read AgentCore thoroughly from line 1 to EOF.")
        #expect(initial[0].status == .running)

        let output = try await tool.runLive(arguments: args) { live in
            recorder.record(live)
        }
        #expect(!recorder.all.isEmpty)
        let finalSubs = try #require(output.subagents)
        #expect(finalSubs.count == 2)
        #expect(finalSubs[0].status == .completed)
        #expect(finalSubs[0].model == "particle-ai/particle-1")
        #expect(finalSubs[0].toolCallCount == 3)
        #expect(finalSubs[0].toolSummaries.count == 3)
        #expect(finalSubs[0].output.contains("Complete line-by-line report"))
        #expect(finalSubs[1].status == .failed)
        #expect(finalSubs[1].toolSummaries.count == 2)
        #expect(!output.isError, "One succeeding sub-agent keeps the overall report usable")

        // 2. Mid-flight cancellation preserves partial sub-agent actions without crashing
        let cancelCoordinator = AgentHelperCoordinator(
            lead: lead,
            definitions: definitions,
            context: "Full read",
            spendLimit: nil
        ) { invocation in
            invocation.onLiveProgress?(AgentLiveProgress(
                model: "particle-ai/particle-1",
                toolCallCount: 4,
                latestActivity: "Reading ChatSession.swift · lines 1–1500",
                toolSummaries: ["Read A.swift", "Read B.swift", "Read C.swift", "Reading ChatSession.swift · lines 1–1500"]
            ))
            try await Task.sleep(nanoseconds: 5_000_000_000)
            return AgentExecutionResult(output: "done")
        }
        let cancelTask = Task {
            try await cancelCoordinator.launch([
                (agentID: "context-gatherer", task: "Read App/Sources line by line"),
                (agentID: "context-gatherer", task: "Read AgentCore/Sources line by line"),
            ])
        }
        try await Task.sleep(nanoseconds: 25_000_000)
        cancelTask.cancel()
        let cancelledResults = try await cancelTask.value
        #expect(cancelledResults.count == 2)
        #expect(cancelledResults.allSatisfy { $0.status == "cancelled" })
        #expect(cancelledResults.allSatisfy { $0.toolCallCount == 4 })
    }

    @Test("Legacy Build 80 launch_helpers records without detail/result still resolve tappable sub-agent cards")
    func legacyLaunchHelpersFallbackAndCodableRoundTrip() throws {
        let legacyArgs = """
        {"helpers":[{"agent_id":"context-gatherer","task":"Read WorkflowEngine.swift and CloudRunner.swift completely."},{"agent_id":"context-gatherer","task":"Read ConnectorClient.swift and DataRepoSync.swift completely."}]}
        """
        var record = ToolCallRecord(
            id: "call-legacy-80",
            name: "launch_helpers",
            arguments: legacyArgs,
            summary: "Sub-agents (2): Context Gatherer, Context Gatherer…",
            status: .running
        )
        let runningItems = SubagentRunItem.resolvedItems(for: record)
        #expect(runningItems.count == 2)
        #expect(runningItems[0].name == "Context Gatherer")
        #expect(runningItems[0].task.contains("WorkflowEngine.swift"))
        #expect(runningItems[0].status == .running)
        #expect(runningItems[1].task.contains("ConnectorClient.swift"))

        // Simulate cold-launch settle when detail and result were nil
        record.status = .failed
        record.detail = "Interrupted when the app closed"
        let settledItems = SubagentRunItem.resolvedItems(for: record)
        #expect(settledItems.count == 2)
        #expect(settledItems.allSatisfy { $0.status == .cancelled })

        // Verify JSON persistence round-trip of structured subagents on Chat
        record.subagents = settledItems
        var step = AssistantStep()
        step.toolCalls = [record]
        var chat = Chat(title: "Subagent Persistence")
        chat.messages.append(.user("Test"))
        chat.messages.append(ChatMessage(body: .assistant(AssistantTurn(status: .stopped, steps: [step]))))
        let encoded = try JSONEncoder().encode(chat)
        let decoded = try JSONDecoder().decode(Chat.self, from: encoded)
        let roundTripped = decoded.lastAssistantTurn?.steps.first?.toolCalls.first?.subagents
        #expect(roundTripped == settledItems)
    }

    @Test("Context Gatherer uses full model strength & thorough line-by-line rules, and sub-agents suppress ask_user")
    func contextGathererPolicyAndSubagentAskUserSuppression() async throws {
        let gatherer = try #require(BuiltInAgents.named("context-gatherer"))
        #expect(gatherer.difficulty == .hard)
        #expect(gatherer.modelPolicy == .automatic)
        #expect(gatherer.instructions.contains("line 1 to its final line"))
        #expect(!gatherer.instructions.lowercased().hasPrefix("quickly locate"))

        let prompt = SystemPrompt.make(userLogin: "owner", repo: nil)
        #expect(prompt.contains("read every assigned file completely from line 1 to its final line"))

        // Verify allowAskUser: false suppresses ask_user on sub-agent turns while default true keeps it on main turns
        final class BodyCaptureTransport: HTTPTransport, @unchecked Sendable {
            private let lock = NSLock()
            var bodies: [JSONValue] = []
            func send(_ request: HTTPRequest) async throws -> HTTPResponse {
                HTTPResponse(status: 200, headers: [:], body: Data())
            }
            func stream(_ request: HTTPRequest) async throws -> HTTPStreamResponse {
                if let body = request.body, let parsed = JSONValue.parse(String(decoding: body, as: UTF8.self)) {
                    lock.withLock { bodies.append(parsed) }
                }
                let sse = "data: {\"choices\":[{\"delta\":{\"content\":\"Done.\"},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n"
                return HTTPStreamResponse(
                    status: 200,
                    headers: [:],
                    body: AsyncThrowingStream { continuation in
                        continuation.yield(Data(sse.utf8))
                        continuation.finish()
                    }
                )
            }
        }

        let transport = BodyCaptureTransport()
        let route = ModelRouter.route(
            choice: .model("particle-ai/particle-1"),
            difficulty: .hard,
            thinking: .max,
            account: AccountState(),
            catalogue: [:]
        )
        let env = AgentEnvironment(
            openRouter: OpenRouterClient(transport: transport, apiKey: "sk-test"),
            freeRoute: { route },
            onOutOfCredits: {}
        )
        var chat = Chat(model: .model("particle-ai/particle-1"), thinking: .max)
        chat.messages.append(.user("Inspect everything"))
        chat.messages.append(ChatMessage(body: .assistant(AssistantTurn())))

        let subInput = AgentTurnInput(
            chat: chat,
            route: route,
            systemPrompt: "subagent",
            tools: [LiveStatusTool { "ok" }],
            allowTools: true,
            agent: gatherer,
            allowAskUser: false
        )
        for await _ in AgentLoop.run(subInput, environment: env) {}
        let sentToolNames = transport.bodies.first?["tools"]?.arrayValue?.compactMap { $0["function"]?["name"]?.stringValue } ?? []
        #expect(sentToolNames == ["introspect"])
        #expect(!sentToolNames.contains("ask_user"))
    }
}
