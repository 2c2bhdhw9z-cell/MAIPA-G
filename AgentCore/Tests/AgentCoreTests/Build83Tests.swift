import Foundation
import Testing
@testable import AgentCore

@Suite("Build 83 — Kiro Non-Stopping Steering, Durable Sub-Agent Resume, Stable Card IDs, & API Key Sanitization")
struct Build83Tests {

    @Test("Kiro mid-turn steering folds into multi-step turns without stopping, persists on AssistantStep, and drains end-of-turn races")
    func kiroMidTurnSteeringPersistsAcrossMultiStepTurnsWithoutStopping() async throws {
        actor StepRecorder {
            var requestMessages: [[JSONValue]] = []
            var stepNumber = 0
            func record(_ body: JSONValue) -> Int {
                let msgs = body["messages"]?.arrayValue ?? []
                requestMessages.append(msgs)
                stepNumber += 1
                return stepNumber
            }
            func allRequests() -> [[JSONValue]] { requestMessages }
        }

        struct SlowEchoTool: AgentTool {
            let name = "slow_echo"
            let onStarted: @Sendable () async -> Void
            var spec: ToolSpec {
                ToolSpec(
                    name: name,
                    description: "Echoes text after allowing live steering to arrive.",
                    parameters: ["type": "object", "properties": ["value": ["type": "string"]]]
                )
            }
            func runningSummary(for arguments: JSONValue) -> String { "Reading \(arguments.optionalString("value") ?? "file")…" }
            func run(arguments: JSONValue, progress: @escaping @Sendable (String) -> Void) async throws -> ToolOutput {
                await onStarted()
                try await Task.sleep(nanoseconds: 50_000_000)
                let val = arguments.optionalString("value") ?? "ok"
                return ToolOutput(forModel: "echo:\(val)", summary: "Read \(val)")
            }
        }

        let recorder = StepRecorder()
        final class MultiStepTransport: HTTPTransport, @unchecked Sendable {
            let recorder: StepRecorder
            init(recorder: StepRecorder) { self.recorder = recorder }
            func send(_ request: HTTPRequest) async throws -> HTTPResponse {
                HTTPResponse(status: 200, headers: [:], body: Data())
            }
            func stream(_ request: HTTPRequest) async throws -> HTTPStreamResponse {
                let parsed = request.body.flatMap { JSONValue.parse(String(decoding: $0, as: UTF8.self)) } ?? .object([:])
                let step = await recorder.record(parsed)
                let sse: String
                switch step {
                case 1:
                    sse = """
                    data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"slow_echo","arguments":"{\\"value\\":\\"first.swift\\"}"}}]},"finish_reason":"tool_calls"}]}

                    data: [DONE]

                    """
                case 2:
                    sse = """
                    data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_2","type":"function","function":{"name":"slow_echo","arguments":"{\\"value\\":\\"second.swift\\"}"}}]},"finish_reason":"tool_calls"}]}

                    data: [DONE]

                    """
                default:
                    sse = """
                    data: {"choices":[{"delta":{"content":"All done following your live steering."},"finish_reason":"stop"}]}

                    data: [DONE]

                    """
                }
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

        let steeringInbox = SteeringInbox()
        let steeredOnce = LockFlag()
        let tool = SlowEchoTool {
            if steeredOnce.setIfFalse() {
                // Inject a Kiro mid-turn steer while Step 1's tool is actively running — WITHOUT cancelling!
                await steeringInbox.enqueue("Focus only on security boundaries, skip formatting.")
            }
        }

        let route = ModelRouter.route(
            choice: .model("particle-ai/particle-1"),
            difficulty: .normal,
            thinking: .medium,
            account: AccountState(),
            catalogue: [:]
        )
        let env = AgentEnvironment(
            openRouter: OpenRouterClient(transport: MultiStepTransport(recorder: recorder), apiKey: "sk-test"),
            freeRoute: { route },
            onOutOfCredits: {}
        )
        var chat = Chat(model: .model("particle-ai/particle-1"))
        chat.messages.append(.user("Audit the codebase"))
        chat.messages.append(ChatMessage(body: .assistant(AssistantTurn())))

        let run = AgentLoop.start(
            AgentTurnInput(
                chat: chat,
                route: route,
                systemPrompt: "system",
                tools: [tool],
                steering: steeringInbox
            ),
            environment: env
        )

        var finalTurn: AssistantTurn?
        for await event in run.events {
            if case .updated(let turn, _) = event {
                finalTurn = turn
            }
        }

        let completed = try #require(finalTurn)
        // Turn finished naturally (.done), NEVER cancelled to .stopped!
        #expect(completed.status == .done)
        #expect(completed.steps.count == 3)
        #expect(completed.steps[0].steeredMessages == nil)
        #expect(completed.steps[1].steeredMessages == ["Focus only on security boundaries, skip formatting."])
        #expect(completed.steps[2].steeredMessages == nil)
        #expect(completed.steps[2].text == "All done following your live steering.")

        // Verify Step 2 AND Step 3 BOTH received the steered instruction exactly once (zero amnesia on Step N+2!)
        let requests = await recorder.allRequests()
        #expect(requests.count == 3)
        let step2UserTexts = requests[1].compactMap { $0["content"]?.stringValue }.filter { $0.contains("Focus only on security boundaries") }
        let step3UserTexts = requests[2].compactMap { $0["content"]?.stringValue }.filter { $0.contains("Focus only on security boundaries") }
        #expect(step2UserTexts.count == 1)
        #expect(step3UserTexts.count == 1)

        // Verify JSON persistence keeps `steeredMessages` and `queuedFollowUps` intact across restarts
        chat.messages[chat.messages.count - 1].assistantTurn = completed
        chat.queuedFollowUps = [QueuedFollowUp(text: "Write unit tests next")]
        let data = try JSONCoding.encoder().encode(chat)
        let reloaded = try JSONCoding.decoder().decode(Chat.self, from: data)
        #expect(reloaded.lastAssistantTurn?.steps[1].steeredMessages == ["Focus only on security boundaries, skip formatting."])
        #expect(reloaded.queuedFollowUps?.map(\.text) == ["Write unit tests next"])

        // Verify `removeFirst(matching:)` and `drainUnconsumedSteering()` for end-of-turn race (`KiroCrew#20549`)
        await steeringInbox.enqueue("Draft typo")
        await steeringInbox.enqueue("Keep going on part 2")
        let removed = await steeringInbox.removeFirst(matching: "Draft typo")
        #expect(removed == true)
        let unconsumed = await run.drainUnconsumedSteering()
        #expect(unconsumed == ["Keep going on part 2"])
    }

    @Test("Durable sub-agent resume preserves completed SubagentRunItems through HookedTool and keeps card IDs stable")
    func durableSubagentResumeSkipsCompletedAndKeepsStableCardIDs() async throws {
        let gatherer = try #require(BuiltInAgents.named("context-gatherer"))
        var lead = try #require(BuiltInAgents.named("coder"))
        lead.maximumHelpers = 8

        actor RunCounter {
            var executedTasks: [String] = []
            func record(_ task: String) { executedTasks.append(task) }
            func tasks() -> [String] { executedTasks }
        }
        let counter = RunCounter()

        let coordinator = AgentHelperCoordinator(
            lead: lead,
            definitions: [gatherer],
            context: "Read whole repo",
            spendLimit: nil
        ) { invocation in
            await counter.record(invocation.task)
            invocation.onLiveProgress?(AgentLiveProgress(
                model: "nvidia/nemotron-3.5-super-vl:free",
                toolCallCount: 4,
                latestActivity: "Reading Part3.swift…",
                toolSummaries: ["Read Part3.swift", "Read Part3B.swift", "Read Part3C.swift", "Read Part3D.swift"],
                liveThought: String(repeating: "Analyzing architecture deeply. ", count: 35),
                partialOutput: "### Part 3 Findings\nAll routes verified."
            ))
            return AgentExecutionResult(
                output: "### Part 3 Complete\n4 files verified.",
                model: "nvidia/nemotron-3.5-super-vl:free",
                cost: 0,
                toolCallCount: 4,
                toolSummaries: ["Read Part3.swift", "Read Part3B.swift", "Read Part3C.swift", "Read Part3D.swift"],
                status: "completed"
            )
        }

        let launchTool = LaunchHelpersTool(lead: lead, definitions: [gatherer], coordinator: coordinator)
        // Wrap in HookedTool just like repo-connected chats do in production!
        let hooked = HookedTool(launchTool, hooks: [], runCommand: nil)

        let argsText = """
        {
          "helpers": [
            {"agent_id": "context-gatherer", "task": "Read Part 1"},
            {"agent_id": "context-gatherer", "task": "Read Part 2"},
            {"agent_id": "context-gatherer", "task": "Read Part 3"}
          ]
        }
        """
        let callID = "call_resume_407c9f71"
        let parsedArgs = try #require(JSONValue.parse(argsText))
        let initialItems = try #require(hooked.initialSubagents(for: parsedArgs, callID: callID))
        let initialIDs = initialItems.map(\.id)
        #expect(initialIDs == ["\(callID)-sub-1", "\(callID)-sub-2", "\(callID)-sub-3"])

        // Simulate 2 finished sub-agents (63 & 183 actions) and 1 background-cancelled sub-agent before foreground resume
        let checkpointedSubagents: [SubagentRunItem] = [
            SubagentRunItem(
                id: "\(callID)-sub-1",
                agentID: "context-gatherer",
                name: "Context Gatherer",
                task: "Read Part 1",
                model: "nvidia/nemotron-3.5-super-vl:free",
                status: .completed,
                toolCallCount: 63,
                latestActivity: "Completed",
                toolSummaries: ["Read A.swift"],
                output: "### Part 1 Complete\n63 actions preserved."
            ),
            SubagentRunItem(
                id: "\(callID)-sub-2",
                agentID: "context-gatherer",
                name: "Context Gatherer",
                task: "Read Part 2",
                model: "nvidia/nemotron-3.5-super-vl:free",
                status: .completed,
                toolCallCount: 183,
                latestActivity: "Completed",
                toolSummaries: ["Read B.swift"],
                output: "### Part 2 Complete\n183 actions preserved."
            ),
            SubagentRunItem(
                id: "\(callID)-sub-3",
                agentID: "context-gatherer",
                name: "Context Gatherer",
                task: "Read Part 3",
                model: "nvidia/nemotron-3.5-super-vl:free",
                status: .cancelled,
                toolCallCount: 12,
                latestActivity: "Stopped",
                toolSummaries: ["Read C.swift"],
                output: ""
            ),
        ]

        var interruptedRecord = ToolCallRecord(
            id: callID,
            name: "launch_helpers",
            arguments: argsText,
            summary: "Sub-agents · stopped",
            status: .failed
        )
        interruptedRecord.detail = "Stopped"
        interruptedRecord.subagents = checkpointedSubagents
        var preStep = AssistantStep()
        preStep.finishedAt = Date()
        preStep.toolCalls = [interruptedRecord]

        final class ResumeFinalStepTransport: HTTPTransport, @unchecked Sendable {
            func send(_ request: HTTPRequest) async throws -> HTTPResponse {
                HTTPResponse(status: 200, headers: [:], body: Data())
            }
            func stream(_ request: HTTPRequest) async throws -> HTTPStreamResponse {
                let sse = "data: {\"choices\":[{\"delta\":{\"content\":\"Combined all 3 sub-agent reports.\"},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n"
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

        let route = ModelRouter.route(
            choice: .model("nvidia/nemotron-3.5-super-vl:free"),
            difficulty: .hard,
            thinking: .high,
            account: AccountState(),
            catalogue: [:]
        )
        let env = AgentEnvironment(
            openRouter: OpenRouterClient(transport: ResumeFinalStepTransport(), apiKey: "sk-test"),
            freeRoute: { route },
            onOutOfCredits: {}
        )
        var chat = Chat(model: .model("nvidia/nemotron-3.5-super-vl:free"))
        chat.messages.append(.user("Use subagents to Read the Whole repo."))
        chat.messages.append(ChatMessage(body: .assistant(AssistantTurn(status: .running, steps: [preStep]))))

        let run = AgentLoop.start(
            AgentTurnInput(chat: chat, route: route, systemPrompt: "sys", tools: [hooked]),
            environment: env
        )

        var observedCardIDSnapshots: [[String]] = []
        var finalTurn: AssistantTurn?
        for await event in run.events {
            if case .updated(let turn, _) = event {
                finalTurn = turn
                if let subs = turn.steps.first?.toolCalls.first?.subagents {
                    observedCardIDSnapshots.append(subs.map(\.id))
                }
            }
        }

        // ONLY Part 3 ran on resume — Part 1 (63 actions) and Part 2 (183 actions) were preserved without restarting!
        let executed = await counter.tasks()
        #expect(executed == ["Read Part 3"])

        // Every single live and final snapshot preserved the exact same SwiftUI card IDs!
        #expect(!observedCardIDSnapshots.isEmpty)
        for ids in observedCardIDSnapshots {
            #expect(ids == initialIDs)
        }

        let finishedSubs = try #require(finalTurn?.steps.first?.toolCalls.first?.subagents)
        #expect(finishedSubs.count == 3)
        #expect(finishedSubs[0].toolCallCount == 63)
        #expect(finishedSubs[0].output.contains("63 actions preserved"))
        #expect(finishedSubs[1].toolCallCount == 183)
        #expect(finishedSubs[1].output.contains("183 actions preserved"))
        #expect(finishedSubs[2].toolCallCount == 4)
        #expect(finishedSubs[2].status == .completed)
        #expect(finalTurn?.status == .done)
    }

    @Test("AIProviderEndpoint.sanitizeAPIKey cleans pasted keys across TeamoRouter, OneProvider, SayGM, OmniRoute, OpenRouter, and Custom")
    func sanitizeAPIKeyHandlesAllPasteFormats() {
        #expect(AIProviderEndpoint.sanitizeAPIKey("  sk-teamo-abc123\n") == "sk-teamo-abc123")
        #expect(AIProviderEndpoint.sanitizeAPIKey("Bearer sk-teamo-abc123") == "sk-teamo-abc123")
        #expect(AIProviderEndpoint.sanitizeAPIKey("Authorization: Bearer \"sk-teamo-abc123\"") == "sk-teamo-abc123")
        #expect(AIProviderEndpoint.sanitizeAPIKey("x-api-key: 'sk-ant-999'") == "sk-ant-999")
        #expect(AIProviderEndpoint.sanitizeAPIKey("export TEAMO_API_KEY=“sk-teamo-smartquotes”;") == "sk-teamo-smartquotes")
        #expect(AIProviderEndpoint.sanitizeAPIKey("\u{FEFF}\u{200B}sk-or-v1-clean\u{200D}\u{00A0}") == "sk-or-v1-clean")
        let multilineEnv = """
        # TeamoRouter production key
        TEAMOROUTER_API_KEY="sk-teamo-multiline-777"
        """
        #expect(AIProviderEndpoint.sanitizeAPIKey(multilineEnv) == "sk-teamo-multiline-777")

        let ep = AIProviderEndpoint(
            id: "teamorouter",
            name: "TeamoRouter",
            baseURL: "https://api.teamorouter.com/v1",
            apiKey: "Authorization: Bearer \"sk-teamo-live-key\"\n"
        )
        #expect(ep.apiKey == "sk-teamo-live-key")
        #expect(ep.isReady == true)
    }
}

private final class LockFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func setIfFalse() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if value { return false }
        value = true
        return true
    }
}
