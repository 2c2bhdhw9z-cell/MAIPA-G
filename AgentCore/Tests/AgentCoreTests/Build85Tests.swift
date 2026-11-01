import Foundation
import Testing
@testable import AgentCore

@Suite("Build 85 — Binary Token Math, Safe Output Token Caps, Non-Blocking Sub-Agent Steering, & Graceful Stop")
struct Build85Tests {

    @Test("Binary token math formats 131,072 as 128K and 1,048,576 as 1M while preserving round decimal caps")
    func binaryAndDecimalTokenMath() {
        #expect(ModelInfo.formattedTokenCount(16_384) == "16K")
        #expect(ModelInfo.formattedTokenCount(32_768) == "32K")
        #expect(ModelInfo.formattedTokenCount(65_536) == "64K")
        #expect(ModelInfo.formattedTokenCount(131_072) == "128K")
        #expect(ModelInfo.formattedTokenCount(204_800) == "200K")
        #expect(ModelInfo.formattedTokenCount(262_144) == "256K")
        #expect(ModelInfo.formattedTokenCount(524_288) == "512K")
        #expect(ModelInfo.formattedTokenCount(1_048_576) == "1M")
        #expect(ModelInfo.formattedTokenCount(2_097_152) == "2M")

        // Round decimal caps stay untouched
        #expect(ModelInfo.formattedTokenCount(16_000) == "16K")
        #expect(ModelInfo.formattedTokenCount(64_000) == "64K")
        #expect(ModelInfo.formattedTokenCount(128_000) == "128K")
        #expect(ModelInfo.formattedTokenCount(200_000) == "200K")
        #expect(ModelInfo.formattedTokenCount(1_000_000) == "1M")
    }

    @Test("Synthetic ~90% provider max_output_tokens fallbacks (943,718 on Kimi K3.1 Pro) are normalized and clamped in outgoing payloads")
    func syntheticMaxOutputTokensNormalizedAndClamped() throws {
        // 1. SayGM / LiteLLM synthetic 90% fallback: 943,718 on 1,048,576 context
        let normalized = AIProviderGateway.normalizeReportedMaxOutputTokens(
            reported: 943_718,
            contextLength: 1_048_576,
            lowerID: "moonshotai/kimi-k3.1-pro"
        )
        #expect(normalized.wasSynthetic == true)
        #expect(normalized.cap == 65_536)
        #expect(ModelInfo.formattedTokenCount(try #require(normalized.cap)) == "64K")

        // Genuine 131,072 (128K) output cap on a 1M model is NOT flagged as synthetic
        let genuine = AIProviderGateway.normalizeReportedMaxOutputTokens(
            reported: 131_072,
            contextLength: 1_048_576,
            lowerID: "deepseek/deepseek-v4"
        )
        #expect(genuine.wasSynthetic == false)
        #expect(genuine.cap == 131_072)

        // 2. Outgoing payload cap is injected for synthetic-cap models AND dynamically clamped against input tokens
        let kimiModel = ModelInfo(
            id: "saygm::kimi-k3.1-pro",
            name: "SayGM: Kimi K3.1 Pro",
            contextLength: 1_048_576,
            maxCompletionTokens: normalized.cap,
            hadSyntheticMaxOutput: true,
            supportedParameters: ["tools", "reasoning"]
        )
        let smallPromptCap = AIProviderGateway.safeOutgoingMaxTokens(
            requested: nil,
            catalogueModel: kimiModel,
            rawModelID: "kimi-k3.1-pro",
            messages: [.system("You are helpful."), .user("Hello")],
            tools: nil
        )
        #expect(smallPromptCap == 65_536)

        // Simulate a huge prompt (~1,014,000 estimated tokens -> 3,650,000 chars) so headroom < 65,536
        let hugeText = String(repeating: "a", count: 3_650_000)
        let clampedCap = try #require(AIProviderGateway.safeOutgoingMaxTokens(
            requested: nil,
            catalogueModel: kimiModel,
            rawModelID: "kimi-k3.1-pro",
            messages: [.user(hugeText)],
            tools: nil
        ))
        let estInput = Transcript.estimatedTokens([.user(hugeText)])
        #expect(clampedCap < 65_536)
        #expect(estInput + clampedCap < 1_048_576)
    }

    @Test("Live Steer while a sub-agent is running immediately wakes AgentLoop without cancelling the running sub-agent")
    func liveSteeringDuringSubagentRunsParallelWithoutStopping() async throws {
        actor Timeline {
            var events: [String] = []
            var stepCount = 0
            var sub1Cancelled = false
            var sub1Finished = false
            var sub2LaunchedWhileSub1Running = false

            func nextStep() -> Int {
                stepCount += 1
                return stepCount
            }
            func mark(_ event: String) { events.append(event) }
            func markSub1Cancelled() { sub1Cancelled = true }
            func markSub1Finished() { sub1Finished = true }
            func markSub2Started() {
                if !sub1Finished { sub2LaunchedWhileSub1Running = true }
            }
        }

        let timeline = Timeline()
        let steering = SteeringInbox()
        let sub1StartedGate = AsyncStream<Void>.makeStream()

        var lead = try #require(BuiltInAgents.named("coder"))
        lead.maximumHelpers = 8
        let definitions = BuiltInAgents.kiroSubagents

        let coordinator = AgentHelperCoordinator(
            lead: lead,
            definitions: definitions,
            context: "Audit repo",
            spendLimit: nil,
            steering: steering
        ) { invocation in
            if invocation.task.contains("FIRST_TASK") {
                await timeline.mark("sub1:start")
                invocation.onLiveProgress?(AgentLiveProgress(
                    model: "nvidia/nemotron:free",
                    toolCallCount: 12,
                    latestActivity: "Reading ChatSession.swift",
                    toolSummaries: ["Reading ChatSession.swift"]
                ))
                sub1StartedGate.continuation.yield(())
                do {
                    try await Task.sleep(nanoseconds: 220_000_000)
                } catch {
                    await timeline.markSub1Cancelled()
                    throw error
                }
                await timeline.markSub1Finished()
                await timeline.mark("sub1:done")
                return AgentExecutionResult(
                    output: "FIRST_REPORT_COMPLETE",
                    model: "nvidia/nemotron:free",
                    cost: 0,
                    toolCallCount: 90,
                    toolSummaries: ["Read 90 files"],
                    status: "completed"
                )
            } else {
                await timeline.markSub2Started()
                await timeline.mark("sub2:start")
                try await Task.sleep(nanoseconds: 40_000_000)
                await timeline.mark("sub2:done")
                return AgentExecutionResult(
                    output: "SECOND_REPORT_COMPLETE",
                    model: "nvidia/nemotron:free",
                    cost: 0,
                    toolCallCount: 15,
                    toolSummaries: ["Read 15 files"],
                    status: "completed"
                )
            }
        }

        let launchTool = LaunchHelpersTool(lead: lead, definitions: definitions, coordinator: coordinator)

        final class SteeredSubagentTransport: HTTPTransport, @unchecked Sendable {
            let timeline: Timeline
            init(timeline: Timeline) { self.timeline = timeline }
            func send(_ request: HTTPRequest) async throws -> HTTPResponse {
                HTTPResponse(status: 200, headers: [:], body: Data())
            }
            func stream(_ request: HTTPRequest) async throws -> HTTPStreamResponse {
                let step = await timeline.nextStep()
                let sse: String
                switch step {
                case 1:
                    sse = """
                    data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_sub_1","type":"function","function":{"name":"launch_helpers","arguments":"{\\"helpers\\":[{\\"agent_id\\":\\"context-gatherer\\",\\"task\\":\\"FIRST_TASK\\"}]}"}}]},"finish_reason":"tool_calls"}]}

                    data: [DONE]

                    """
                case 2:
                    // Triggered immediately by live Steer while Sub-Agent 1 is STILL running!
                    sse = """
                    data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_sub_2","type":"function","function":{"name":"launch_helpers","arguments":"{\\"helpers\\":[{\\"agent_id\\":\\"semantic-reviewer\\",\\"task\\":\\"SECOND_TASK\\"}]}"}}]},"finish_reason":"tool_calls"}]}

                    data: [DONE]

                    """
                case 3:
                    // Quick interim acknowledgement while Sub-Agent 1 finishes in background
                    sse = """
                    data: {"choices":[{"delta":{"content":"Launched the second sub-agent while the first continues!"},"finish_reason":"stop"}]}

                    data: [DONE]

                    """
                default:
                    // Final synthesis after background Sub-Agent 1 delivers its report
                    sse = """
                    data: {"choices":[{"delta":{"content":"Both sub-agents finished cleanly."},"finish_reason":"stop"}]}

                    data: [DONE]

                    """
                }
                let bytes = Data(sse.utf8)
                return HTTPStreamResponse(status: 200, headers: ["content-type": "text/event-stream"], body: AsyncThrowingStream { cont in
                    cont.yield(bytes)
                    cont.finish()
                })
            }
        }

        var chat = Chat(title: "Parallel Steer")
        chat.messages.append(.user("Inspect the codebase"))
        let route = Route(
            model: "nvidia/nemotron:free",
            plugins: [],
            effort: .medium,
            automaticCaching: false,
            isFree: true,
            isAuto: false,
            label: "Nemotron",
            contextWindow: 262_144,
            contextBudget: 230_000,
            maxOutputTokens: 32_768,
            readsImages: false,
            readsPDFs: false,
            generatesImages: false
        )
        let env = AgentEnvironment(
            openRouter: OpenRouterClient(transport: SteeredSubagentTransport(timeline: timeline), apiKey: "sk-test"),
            freeRoute: { route },
            onOutOfCredits: {}
        )
        let run = AgentLoop.start(
            AgentTurnInput(
                chat: chat,
                route: route,
                systemPrompt: "Test",
                tools: [launchTool],
                steering: steering
            ),
            environment: env
        )

        // Wait until Sub-Agent 1 has started, then immediately send a live Steer!
        var gateIterator = sub1StartedGate.stream.makeAsyncIterator()
        _ = await gateIterator.next()
        await run.steer("Do another sub agent right now")

        var finalTurn: AssistantTurn?
        for await event in run.events {
            if case .updated(let t, _) = event {
                finalTurn = t
            }
        }

        let settled = try #require(finalTurn)
        #expect(settled.status == .done)
        #expect(await timeline.sub1Cancelled == false)
        #expect(await timeline.sub1Finished == true)
        #expect(await timeline.sub2LaunchedWhileSub1Running == true)
        #expect(settled.steps.last?.text == "Both sub-agents finished cleanly.")
        // Verify Sub-Agent 1's card updated all the way to `.completed` with 90 actions!
        let sub1Card = settled.steps.first?.toolCalls.first?.subagents?.first
        #expect(sub1Card?.status == .completed)
        #expect(sub1Card?.toolCallCount == 90)
    }

    @Test("Stopping a running launch_helpers turn settles the tool call as non-failed paused progress")
    func stoppedSubagentToolNotMarkedFailed() async throws {
        var lead = try #require(BuiltInAgents.named("coder"))
        lead.maximumHelpers = 4
        let started = AsyncStream<Void>.makeStream()
        let coordinator = AgentHelperCoordinator(
            lead: lead,
            definitions: BuiltInAgents.kiroSubagents,
            context: "Stop check",
            spendLimit: nil
        ) { invocation in
            invocation.onLiveProgress?(AgentLiveProgress(model: "test/model", toolCallCount: 7, latestActivity: "Reading files"))
            started.continuation.yield(())
            try await Task.sleep(nanoseconds: 10_000_000_000)
            return AgentExecutionResult(output: "done")
        }
        let launchTool = LaunchHelpersTool(lead: lead, definitions: BuiltInAgents.kiroSubagents, coordinator: coordinator)

        final class SingleLaunchTransport: HTTPTransport, @unchecked Sendable {
            func send(_ request: HTTPRequest) async throws -> HTTPResponse {
                HTTPResponse(status: 200, headers: [:], body: Data())
            }
            func stream(_ request: HTTPRequest) async throws -> HTTPStreamResponse {
                let sse = """
                data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_stop_1","type":"function","function":{"name":"launch_helpers","arguments":"{\\"helpers\\":[{\\"agent_id\\":\\"context-gatherer\\",\\"task\\":\\"Read files\\"}]}"}}]},"finish_reason":"tool_calls"}]}

                data: [DONE]

                """
                return HTTPStreamResponse(status: 200, headers: ["content-type": "text/event-stream"], body: AsyncThrowingStream { cont in
                    cont.yield(Data(sse.utf8))
                    cont.finish()
                })
            }
        }

        var chat = Chat(title: "Stop Test")
        chat.messages.append(.user("Start helper"))
        let route = Route(
            model: "test/model",
            plugins: [],
            effort: nil,
            automaticCaching: false,
            isFree: true,
            isAuto: false,
            label: "Test",
            contextWindow: 128_000,
            contextBudget: 100_000,
            maxOutputTokens: 16_384,
            readsImages: false,
            readsPDFs: false,
            generatesImages: false
        )
        let env = AgentEnvironment(
            openRouter: OpenRouterClient(transport: SingleLaunchTransport(), apiKey: "sk-test"),
            freeRoute: { route },
            onOutOfCredits: {}
        )
        let run = AgentLoop.start(AgentTurnInput(chat: chat, route: route, systemPrompt: "s", tools: [launchTool]), environment: env)

        var iter = started.stream.makeAsyncIterator()
        _ = await iter.next()
        try await Task.sleep(nanoseconds: 30_000_000)
        run.cancel()

        var finalTurn: AssistantTurn?
        for await event in run.events {
            if case .updated(let t, _) = event { finalTurn = t }
        }
        let stoppedTurn = try #require(finalTurn)
        #expect(stoppedTurn.status == .stopped)
        let toolRecord = try #require(stoppedTurn.steps.first?.toolCalls.first)
        // Not marked `.failed`, so resuming never misleads the model into thinking sub-agents are broken!
        #expect(toolRecord.status == .done)
        #expect(toolRecord.result?.contains("not a tool failure") == true)
        #expect(toolRecord.subagents?.first?.status == .cancelled)
    }

    @Test("SayGM /v1/credits (balance.usd + balance.nano_usd) and OmniRoute api.cheaperinference.com balance parsing")
    func saygmAndOmniRouteBalanceParsing() async throws {
        // 1. SayGM CreditBalanceResponse schema (`balance.usd` decimal string + `balance.nano_usd`)
        let saygmJSON = try #require(JSONValue.parse(Data(#"{"object":"credit_balance","balance":{"usd":"12.345678901","nano_usd":12345678901},"spent":{"usd":"1.200000000","nano_usd":1200000000}}"#.utf8)))
        let saygmUSD = try #require(AIProviderGateway.parseBalanceJSON(saygmJSON))
        #expect(abs(saygmUSD - 12.345678901) < 0.000_001)

        // SayGM nano_usd-only fallback
        let saygmNanoOnly = try #require(JSONValue.parse(Data(#"{"object":"credit_balance","balance":{"nano_usd":5500000000}}"#.utf8)))
        let nanoUSD = try #require(AIProviderGateway.parseBalanceJSON(saygmNanoOnly))
        #expect(abs(nanoUSD - 5.5) < 0.000_001)

        // 2. OmniRoute with legacy `platform.cheaperinference.com/v1` baseURL still resolves balance via `api.cheaperinference.com/v1/account/balance`
        final class BalanceTransport: HTTPTransport, @unchecked Sendable {
            func send(_ request: HTTPRequest) async throws -> HTTPResponse {
                if request.url.host == "api.cheaperinference.com" && request.url.path == "/v1/account/balance" {
                    return HTTPResponse(status: 200, headers: [:], body: Data(#"{"available_usd":8.75,"balance_usd":10.00,"reserved_usd":1.25}"#.utf8))
                }
                return HTTPResponse(status: 404, headers: [:], body: Data("Not Found".utf8))
            }
            func stream(_ request: HTTPRequest) async throws -> HTTPStreamResponse {
                HTTPStreamResponse(status: 404, headers: [:], body: AsyncThrowingStream { $0.finish() })
            }
        }
        let legacyOmni = AIProviderEndpoint(
            id: "omniroute",
            name: "OmniRoute",
            baseURL: "https://platform.cheaperinference.com/v1",
            apiKey: "ci_live_test",
            isEnabled: true
        )
        let omniBalance = try #require(await AIProviderGateway.fetchBalance(for: legacyOmni, transport: BalanceTransport()))
        #expect(abs(omniBalance - 8.75) < 0.000_001)
    }

    @Test("ModelInfo.sanitized normalizes cached catalogue models (943,718 -> 65,536 and 235,929 -> 65,536)")
    func cachedModelSanitizedNormalizesSyntheticOutputCaps() throws {
        let staleKimiK31 = ModelInfo(
            id: "moonshotai/kimi-k3.1-pro",
            name: "MoonshotAI: Kimi K3.1 Pro",
            contextLength: 1_048_576,
            maxCompletionTokens: 943_718,
            supportedParameters: ["tools", "reasoning"]
        ).sanitized
        #expect(staleKimiK31.maxCompletionTokens == 65_536)
        #expect(staleKimiK31.hadSyntheticMaxOutput == true)
        #expect(ModelInfo.formattedTokenCount(try #require(staleKimiK31.maxCompletionTokens)) == "64K")

        let staleKimiK27 = ModelInfo(
            id: "moonshotai/kimi-k2.7-code",
            name: "MoonshotAI: Kimi K2.7 Code",
            contextLength: 262_144,
            maxCompletionTokens: 235_929,
            supportedParameters: ["tools"]
        ).sanitized
        #expect(staleKimiK27.maxCompletionTokens == 65_536)
        #expect(staleKimiK27.hadSyntheticMaxOutput == true)
    }

    @Test("SubagentRunItem.resolvedItems keeps detached background sub-agents running and marks legacy app-closed runs stopped instead of failed")
    func subagentResolvedItemsBackgroundAndLegacyInterrupted() {
        // 1. Detached background sub-agent (`call.status == .done`, `result` contains `running_in_background`) stays `.running`!
        var detachedCall = ToolCallRecord(
            id: "call-bg",
            name: "launch_helpers",
            arguments: #"{"helpers":[{"agent_id":"verification-subagent","task":"Verify repo"}]}"#,
            summary: "1 sub-agent running in background (14 actions)",
            status: .done,
            subagents: [
                SubagentRunItem(
                    id: "call-bg-sub-0",
                    agentID: "verification-subagent",
                    name: "Verification Sub-Agent",
                    task: "Verify repo",
                    model: "nvidia/nemotron:free",
                    status: .running,
                    toolCallCount: 14,
                    latestActivity: "Reading ChatSession.swift"
                )
            ]
        )
        detachedCall.detail = "Reading files"
        detachedCall.result = #"{"status":"running_in_background","running_subagents":1}"#
        let detachedResolved = SubagentRunItem.resolvedItems(for: detachedCall)
        #expect(detachedResolved.first?.status == .running)

        // 2. Legacy Build 84 chat (`status == .failed`, `result == "Interrupted when the app closed."`) resolves to `.cancelled` and emits neutral transcript text!
        var legacyCall = ToolCallRecord(
            id: "call-legacy",
            name: "launch_helpers",
            arguments: #"{"helpers":[{"agent_id":"verification-subagent","task":"Audit"}]}"#,
            summary: "Sub-agents running (25 actions)",
            status: .failed,
            subagents: [
                SubagentRunItem(
                    id: "call-legacy-sub-0",
                    agentID: "verification-subagent",
                    name: "Verification Sub-Agent",
                    task: "Audit",
                    status: .running,
                    toolCallCount: 25
                )
            ]
        )
        legacyCall.detail = "### Verification Sub-Agent\nPartial notes"
        legacyCall.result = "Interrupted when the app closed."
        let legacyResolved = SubagentRunItem.resolvedItems(for: legacyCall)
        #expect(legacyResolved.first?.status == .cancelled)

        let transcriptNote = Transcript.toolResultText(for: legacyCall, turnIsCurrent: false)
        #expect(transcriptNote.contains("not a tool failure"))
        #expect(!transcriptNote.contains("This tool did not finish"))
    }
}
