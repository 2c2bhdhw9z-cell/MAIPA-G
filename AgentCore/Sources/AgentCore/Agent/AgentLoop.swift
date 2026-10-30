import Foundation

/// Everything one run of the AI needs.
public struct AgentTurnInput: Sendable {
    /// The chat, ending with the assistant turn to work on: a new empty one after a user message,
    /// or a paused one whose questions now have answers.
    public var chat: Chat
    public var route: Route
    public var systemPrompt: String
    /// The tools besides ask_user, which is always available when tools are.
    public var tools: [any AgentTool]
    /// False for AIs that can't use tools at all: then no tools, not even ask_user, are offered.
    public var allowTools: Bool
    public var maxSteps: Int
    /// "Stop and ask when a job has cost $__", in dollars, or nil when that setting is off.
    public var spendLimit: Double?
    /// Bytes for image/PDF references in the chat, loaded only for the active request.
    public var attachmentData: [UUID: Data]
    /// OpenRouter-run paid tools, offered alongside local tools.
    public var serverTools: [ToolSpec]
    public var fallbackModels: [String]
    /// Paid model requests cannot begin until the person taps the app's spend approval.
    public var requiresInitialSpendApproval: Bool
    /// Fixed role and tool policy when this turn belongs to a named agent.
    public var agent: AgentDefinition?

    public init(chat: Chat, route: Route, systemPrompt: String, tools: [any AgentTool], allowTools: Bool = true, maxSteps: Int = 40, spendLimit: Double? = nil, attachmentData: [UUID: Data] = [:], serverTools: [ToolSpec] = [], fallbackModels: [String] = [], requiresInitialSpendApproval: Bool = false, agent: AgentDefinition? = nil) {
        self.chat = chat
        self.route = route
        self.systemPrompt = systemPrompt
        self.tools = tools
        self.allowTools = allowTools
        self.maxSteps = maxSteps
        self.spendLimit = spendLimit
        self.attachmentData = attachmentData
        self.serverTools = serverTools
        self.fallbackModels = fallbackModels
        self.requiresInitialSpendApproval = requiresInitialSpendApproval
        self.agent = agent
    }
}

public struct AgentEnvironment: Sendable {
    public var openRouter: OpenRouterClient
    /// The route to use when Auto finds the account has no credit left.
    public var freeRoute: @Sendable () -> Route
    /// Told when a paid request is refused for lack of credit, so the app can remember it.
    public var onOutOfCredits: @Sendable () async -> Void
    /// Called with a model OpenRouter refused to MAIPA-G as app-restricted, so it can be hidden.
    public var onModelRestricted: @Sendable (String) async -> Void = { _ in }

    public init(openRouter: OpenRouterClient, freeRoute: @escaping @Sendable () -> Route, onOutOfCredits: @escaping @Sendable () async -> Void) {
        self.openRouter = openRouter
        self.freeRoute = freeRoute
        self.onOutOfCredits = onOutOfCredits
    }
}

/// The run's progress: the whole turn as it stands. A milestone (a step or tool finished) is a
/// good moment to save the chat; the others are the stream of words arriving.
public enum AgentEvent: Sendable {
    case updated(AssistantTurn, milestone: Bool)
}

/// One running turn. `cancel()` stops it the gentle way: whatever the AI already wrote is kept,
/// unfinished tools are marked as stopped, and a last event with the final state still arrives
/// before `events` ends.
public struct AgentRun: Sendable {
    public let events: AsyncStream<AgentEvent>
    private let task: Task<Void, Never>

    init(events: AsyncStream<AgentEvent>, task: Task<Void, Never>) {
        self.events = events
        self.task = task
    }

    public func cancel() {
        task.cancel()
    }
}

/// The agent loop: ask the model, run the tools it asks for, give it the results, and repeat
/// until it answers, needs the user, or is stopped.
public enum AgentLoop {
    public static func start(_ input: AgentTurnInput, environment: AgentEnvironment) -> AgentRun {
        // Every event carries the whole turn, so if the reader falls behind, dropping older ones
        // loses nothing.
        let (events, continuation) = AsyncStream<AgentEvent>.makeStream(bufferingPolicy: .bufferingNewest(256))
        let task = Task {
            var runner = Runner(input: input, environment: environment, continuation: continuation)
            await runner.run()
            continuation.finish()
        }
        continuation.onTermination = { reason in
            if case .cancelled = reason { task.cancel() }
        }
        return AgentRun(events: events, task: task)
    }

    public static func run(_ input: AgentTurnInput, environment: AgentEnvironment) -> AsyncStream<AgentEvent> {
        start(input, environment: environment).events
    }

    /// The plain words a failed turn shows for `error`.
    static func describe(_ error: Error) -> TurnFailure { Runner.describe(error) }
}

private struct Runner {
    var chat: Chat
    var turn: AssistantTurn
    var route: Route
    let systemPrompt: String
    let tools: [String: any AgentTool]
    let specs: [ToolSpec]
    let maxSteps: Int
    let spendLimit: Double?
    let attachmentData: [UUID: Data]
    let fallbackModels: [String]
    let requiresInitialSpendApproval: Bool
    let environment: AgentEnvironment
    let continuation: AsyncStream<AgentEvent>.Continuation
    var switchedToFree = false
    var lastEmit = Date.distantPast

    init(input: AgentTurnInput, environment: AgentEnvironment, continuation: AsyncStream<AgentEvent>.Continuation) {
        chat = input.chat
        turn = input.chat.lastAssistantTurn ?? AssistantTurn()
        if input.chat.lastAssistantTurn == nil {
            chat.messages.append(ChatMessage(body: .assistant(turn)))
        }
        route = input.route
        systemPrompt = input.systemPrompt
        var byName: [String: any AgentTool] = [:]
        var localSpecs: [ToolSpec] = []
        if input.allowTools {
            for tool in input.tools where input.agent?.permits(tool: tool.name) ?? true {
                byName[tool.name] = tool
                localSpecs.append(tool.spec)
            }
        }
        tools = byName
        let serverSpecs = input.serverTools.filter { input.agent?.permits(tool: $0.function.name) ?? true }
        let mayAsk = input.agent?.permits(tool: AskUserTool.name) ?? true
        specs = input.allowTools ? localSpecs + serverSpecs + (mayAsk ? [AskUserTool.spec] : []) : []
        maxSteps = input.maxSteps
        spendLimit = input.spendLimit.flatMap { $0 > 0 ? $0 : nil }
        attachmentData = input.attachmentData
        fallbackModels = input.fallbackModels.filter { $0 != input.route.model }
        requiresInitialSpendApproval = input.requiresInitialSpendApproval
        self.environment = environment
        self.continuation = continuation
    }

    mutating func emit(milestone: Bool) {
        chat.messages[chat.messages.count - 1].assistantTurn = turn
        continuation.yield(.updated(turn, milestone: milestone))
        lastEmit = Date()
    }

    mutating func run() async {
        turn.status = .running
        turn.failure = nil
        turn.spendCheck = nil
        if turn.routeLabel == nil { turn.routeLabel = route.label }
        emit(milestone: true)
        var newSteps = 0
        do {
            while true {
                try Task.checkCancellation()
                if let last = turn.steps.indices.last, turn.steps[last].toolCalls.contains(where: { $0.result == nil }) {
                    if try await runTools(inStep: last) {
                        turn.status = .waitingForUser
                        break
                    }
                    continue
                }
                if let last = turn.steps.last, last.toolCalls.isEmpty, last.finishedAt != nil {
                    turn.status = .done
                    break
                }
                guard newSteps < maxSteps else {
                    turn.status = .stopped
                    turn.failure = TurnFailure(kind: .stepLimit, message: "I stopped after \(maxSteps) steps so this doesn't run up a bill. Tap Keep going if you want more.")
                    break
                }
                // Every paid run needs an explicit, typed approval before its first network call.
                if requiresInitialSpendApproval, turn.approvedSpendUpTo == nil, (turn.usage.cost ?? 0) == 0 {
                    turn.status = .waitingForUser
                    turn.spendCheck = 0
                    break
                }
                // "Stop and ask when a job has cost $__": checked before every request to the AI,
                // since that is where money is spent.
                if let spendLimit {
                    let spent = turn.usage.cost ?? 0
                    if spent >= (turn.approvedSpendUpTo ?? spendLimit) {
                        turn.status = .waitingForUser
                        turn.spendCheck = spent
                        break
                    }
                }
                newSteps += 1
                try await requestStep()
            }
        } catch is CancellationError {
            stopRunningTools(reason: "Stopped")
            turn.status = .stopped
        } catch {
            stopRunningTools(reason: "Didn't finish")
            turn.status = .failed
            turn.failure = Self.describe(error)
            if let api = error as? OpenRouterAPIError, api.kind == .appRestricted {
                await environment.onModelRestricted(route.model)
            }
        }
        if Task.isCancelled, turn.status == .running { turn.status = .stopped }
        emit(milestone: true)
    }

    mutating func stopRunningTools(reason: String) {
        for stepIndex in turn.steps.indices {
            for callIndex in turn.steps[stepIndex].toolCalls.indices where turn.steps[stepIndex].toolCalls[callIndex].status == .running {
                turn.steps[stepIndex].toolCalls[callIndex].status = .failed
                turn.steps[stepIndex].toolCalls[callIndex].detail = reason
                turn.steps[stepIndex].toolCalls[callIndex].finishedAt = Date()
            }
            if turn.steps[stepIndex].finishedAt == nil { turn.steps[stepIndex].finishedAt = Date() }
        }
    }

    // MARK: One request to the model

    mutating func requestStep() async throws {
        var attempt = 0
        while true {
            attempt += 1
            chat.messages[chat.messages.count - 1].assistantTurn = turn
            let (messages, trimmed) = Transcript.fit(Transcript.messages(for: chat, systemPrompt: systemPrompt, attachmentData: attachmentData), budget: route.contextBudget)
            let request = ChatCompletionRequest(
                model: route.model,
                models: fallbackModels.isEmpty ? nil : [route.model] + fallbackModels,
                messages: messages,
                tools: specs,
                reasoningEffort: route.effort,
                plugins: route.plugins,
                sessionID: chat.id.uuidString,
                automaticCaching: route.automaticCaching
            )
            if trimmed, !turn.notices.contains(Self.trimmedNotice) { turn.notices.append(Self.trimmedNotice) }

            turn.steps.append(AssistantStep())
            let index = turn.steps.count - 1
            emit(milestone: false)

            var accumulator = StreamAccumulator()
            do {
                let stream = try await environment.openRouter.stream(request)
                for try await chunk in stream {
                    accumulator.apply(chunk)
                    if let error = chunk.error { throw error }
                    let changed = turn.steps[index].text != accumulator.text || turn.steps[index].reasoning != accumulator.reasoning
                    turn.steps[index].text = accumulator.text
                    turn.steps[index].reasoning = accumulator.reasoning
                    if let model = accumulator.model { turn.steps[index].model = model }
                    // Every new piece of text goes out at once, so words never wait for the next
                    // ones (a model can pause mid-reply). The app draws at most once a frame.
                    if changed { emit(milestone: false) }
                }
                try Task.checkCancellation()
                guard accumulator.hasOutput || !accumulator.reasoning.isEmpty || accumulator.finishReason != nil else {
                    throw OpenRouterAPIError(httpStatus: 502, code: "empty_reply", message: "The AI sent back an empty reply.")
                }
                finish(step: index, with: accumulator)
                if accumulator.finishReason == "length", accumulator.toolCalls.isEmpty {
                    turn.notices.append("This reply hit its length limit and may be cut off.")
                }
                emit(milestone: true)
                return
            } catch {
                let producedOutput = accumulator.hasOutput
                if producedOutput || error is CancellationError || Task.isCancelled {
                    // Keep what arrived; a half-written tool call is not safe to run, so drop those.
                    finish(step: index, with: accumulator, keepToolCalls: false)
                    emit(milestone: true)
                    throw error
                }
                turn.steps.remove(at: index)
                switch await recovery(for: error, attempt: attempt) {
                case .retry(let delay):
                    if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
                    continue
                case .switchToFree:
                    await environment.onOutOfCredits()
                    route = environment.freeRoute()
                    route.isAuto = true
                    route.label = "Auto · free AIs"
                    turn.routeLabel = route.label
                    switchedToFree = true
                    turn.notices.append("You're out of OpenRouter credit, so Auto switched to the free AIs.")
                    emit(milestone: false)
                    continue
                case .shrinkContext:
                    route.contextBudget = max(8_000, route.contextBudget / 2)
                    continue
                case .giveUp:
                    throw error
                }
            }
        }
    }

    mutating func finish(step index: Int, with accumulator: StreamAccumulator, keepToolCalls: Bool = true) {
        var step = turn.steps[index]
        step.finishedAt = Date()
        step.text = accumulator.text
        step.reasoning = accumulator.reasoning
        step.reasoningDetails = accumulator.reasoningDetails
        step.model = accumulator.model ?? step.model
        if let actual = accumulator.model, actual != route.model,
           !turn.notices.contains(where: { $0.contains("switched to fallback AI") }) {
            turn.notices.append("OpenRouter switched to fallback AI \(actual) because the first AI was unavailable.")
        }
        step.usage = accumulator.usage
        step.finishReason = accumulator.finishReason
        step.citations = accumulator.citations.isEmpty ? nil : accumulator.citations
        if keepToolCalls {
            step.toolCalls = accumulator.toolCalls.map { call in
                let arguments = JSONValue.parse(call.function.arguments) ?? .object([:])
                let summary = call.function.name == AskUserTool.name
                    ? "Asking you…"
                    : (tools[call.function.name]?.runningSummary(for: arguments) ?? "Using \(call.function.name)…")
                return ToolCallRecord(id: call.id, name: call.function.name, arguments: call.function.arguments, summary: summary)
            }
        }
        turn.steps[index] = step
    }

    enum Recovery { case retry(TimeInterval), switchToFree, shrinkContext, giveUp }

    func recovery(for error: Error, attempt: Int) async -> Recovery {
        if let api = error as? OpenRouterAPIError {
            switch api.kind {
            case .outOfCredits where route.isAuto && !route.isFree && !switchedToFree:
                return .switchToFree
            case .busyRetrySoon where attempt <= 3:
                return .retry(min(api.retryAfter ?? 3, 20))
            case .rateLimited where attempt <= 2 && (api.retryAfter ?? 5) <= 20:
                return .retry(api.retryAfter ?? Double(attempt) * 4)
            case .providerFailed where attempt <= 2, .noModelAvailable where attempt <= 2:
                return .retry(Double(attempt) * 1.5)
            case .contextTooLong where attempt <= 2:
                return .shrinkContext
            default:
                return .giveUp
            }
        }
        if let http = error as? HTTPError, case .transport(_, let isOffline) = http, !isOffline, attempt <= 2 {
            return .retry(Double(attempt))
        }
        return .giveUp
    }

    static let trimmedNotice = "This chat is long, so some older tool results were left out of what the AI sees."

    // MARK: Tools

    /// Runs the step's unfinished tool calls, all at once. Returns true when the AI asked the user
    /// questions that still need answers.
    mutating func runTools(inStep stepIndex: Int) async throws -> Bool {
        var waiting = false
        var jobs: [(callIndex: Int, tool: any AgentTool, arguments: JSONValue, approved: Bool)] = []

        for callIndex in turn.steps[stepIndex].toolCalls.indices {
            let call = turn.steps[stepIndex].toolCalls[callIndex]
            guard call.result == nil else { continue }
            let repeatedFailures = turn.steps.prefix(stepIndex).flatMap(\.toolCalls).filter {
                $0.name == call.name && $0.arguments == call.arguments && $0.status == .failed
            }.count
            if repeatedFailures >= 2 {
                fail(
                    stepIndex,
                    callIndex,
                    message: "This exact tool call already failed twice. Change the approach or ask the person what to do next.",
                    summary: "Stopped a repeated failing tool call"
                )
                continue
            }
            if call.name == AskUserTool.name {
                if let answers = call.questions?.answerText {
                    turn.steps[stepIndex].toolCalls[callIndex].result = answers
                    turn.steps[stepIndex].toolCalls[callIndex].status = .done
                    turn.steps[stepIndex].toolCalls[callIndex].summary = "You answered"
                    turn.steps[stepIndex].toolCalls[callIndex].finishedAt = Date()
                } else if call.questions != nil {
                    waiting = true
                } else {
                    do {
                        let questions = try AskUserTool.questions(from: call.parsedArguments)
                        turn.steps[stepIndex].toolCalls[callIndex].questions = questions
                        turn.steps[stepIndex].toolCalls[callIndex].status = .waitingForUser
                        turn.steps[stepIndex].toolCalls[callIndex].summary = questions.questions.count == 1 ? "Asked you a question" : "Asked you \(questions.questions.count) questions"
                        waiting = true
                    } catch {
                        fail(stepIndex, callIndex, message: "Error: \(error)", summary: "Tried to ask you something")
                    }
                }
                continue
            }
            guard let tool = tools[call.name] else {
                let available = tools.keys.sorted().joined(separator: ", ")
                fail(stepIndex, callIndex, message: "Error: there is no tool called \(call.name). Available tools: \(available.isEmpty ? "none besides ask_user" : available).", summary: "Tried a tool that doesn't exist")
                continue
            }
            guard let arguments = JSONValue.parse(call.arguments), arguments.objectValue != nil else {
                fail(stepIndex, callIndex, message: "Error: the arguments were not a valid JSON object: \(call.arguments.prefix(200))", summary: tool.runningSummary(for: .object([:])).replacingOccurrences(of: "…", with: "") + " · didn't work")
                continue
            }
            let wasApproved: Bool
            var pendingApproval: ToolApprovalRequest?
            if call.questions == nil {
                pendingApproval = await tool.approvalRequest(for: arguments)
                if pendingApproval == nil, outsideContentSeen() {
                    pendingApproval = await tool.approvalAfterOutsideContent(for: arguments)
                }
            }
            if let questions = call.questions {
                guard let answer = questions.answers?.first else {
                    waiting = true
                    continue
                }
                let allowed = questions.questions.first?.options.first == answer
                guard allowed else {
                    turn.steps[stepIndex].toolCalls[callIndex].result = "The person did not approve this change."
                    turn.steps[stepIndex].toolCalls[callIndex].status = .done
                    turn.steps[stepIndex].toolCalls[callIndex].summary = "Change not approved"
                    turn.steps[stepIndex].toolCalls[callIndex].finishedAt = Date()
                    continue
                }
                wasApproved = true
            } else if let approval = pendingApproval {
                turn.steps[stepIndex].toolCalls[callIndex].questions = QuestionSet(questions: [
                    .init(text: approval.question, options: [approval.allowLabel, "Don't allow"]),
                ])
                turn.steps[stepIndex].toolCalls[callIndex].status = .waitingForUser
                turn.steps[stepIndex].toolCalls[callIndex].summary = "Needs your approval"
                waiting = true
                continue
            } else {
                wasApproved = false
            }
            turn.steps[stepIndex].toolCalls[callIndex].status = .running
            turn.steps[stepIndex].toolCalls[callIndex].summary = tool.runningSummary(for: arguments)
            jobs.append((callIndex, tool, arguments, wasApproved))
        }
        emit(milestone: true)

        if !jobs.isEmpty {
            // The jobs run side by side and report through one stream: progress lines while they
            // work ("Getting a copy of the repo · 12 MB"), then their results.
            enum ToolEvent: Sendable {
                case progress(Int, String)
                case finished(Int, Result<ToolOutput, Error>)
            }
            let (events, sink) = AsyncStream<ToolEvent>.makeStream()
            try await withThrowingTaskGroup(of: Void.self) { group in
                for job in jobs {
                    group.addTask {
                        let result: Result<ToolOutput, Error>
                        do {
                            let output: ToolOutput
                            if job.approved {
                                output = try await job.tool.runApproved(arguments: job.arguments) { message in
                                    sink.yield(.progress(job.callIndex, message))
                                }
                            } else {
                                output = try await job.tool.run(arguments: job.arguments) { message in
                                    sink.yield(.progress(job.callIndex, message))
                                }
                            }
                            result = .success(output)
                        } catch {
                            if error is CancellationError || Task.isCancelled { throw CancellationError() }
                            result = .failure(error)
                        }
                        sink.yield(.finished(job.callIndex, result))
                    }
                }
                var remaining = jobs.count
                for await event in events {
                    switch event {
                    case .progress(let callIndex, let message):
                        if turn.steps[stepIndex].toolCalls[callIndex].status == .running {
                            turn.steps[stepIndex].toolCalls[callIndex].summary = message
                            if Date().timeIntervalSince(lastEmit) > 0.25 { emit(milestone: false) }
                        }
                    case .finished(let callIndex, let result):
                        if case .failure(let error) = result, let approval = error as? ToolApprovalRequired {
                            turn.steps[stepIndex].toolCalls[callIndex].status = .waitingForUser
                            turn.steps[stepIndex].toolCalls[callIndex].summary = "Needs your approval"
                            turn.steps[stepIndex].toolCalls[callIndex].questions = QuestionSet(questions: [
                                .init(text: approval.request.question, options: [approval.request.allowLabel, "Don't allow"]),
                            ])
                            waiting = true
                        } else {
                            apply((callIndex, result), stepIndex: stepIndex)
                        }
                        emit(milestone: true)
                        remaining -= 1
                    }
                    if remaining == 0 { break }
                }
                sink.finish()
                try await group.waitForAll()
            }
        }
        try Task.checkCancellation()
        return waiting
    }

    /// Whether anything from outside the person's own words is in the conversation: OpenRouter's
    /// own web tools (their citations), or a finished call to a tool that brings outside content,
    /// in this turn or an earlier one the AI still sees.
    func outsideContentSeen() -> Bool {
        let earlier = chat.messages.dropLast().compactMap(\.assistantTurn)
        for candidate in earlier + [turn] {
            for step in candidate.steps {
                if !(step.citations ?? []).isEmpty { return true }
                for call in step.toolCalls where call.result != nil && call.status != .waitingForUser {
                    if tools[call.name]?.bringsOutsideContent == true || call.name.hasPrefix("mcp_") || Self.outsideContentToolNames.contains(call.name) { return true }
                }
            }
        }
        return false
    }

    /// Outside-content tools by name, for earlier turns whose tools may not be loaded now.
    static let outsideContentToolNames: Set<String> = ["web_search", "read_web_page", "read_file", "search_code", "read_repo_file", "read_other_repo_file"]

    mutating func apply(_ result: (Int, Result<ToolOutput, Error>), stepIndex: Int) {
        let callIndex = result.0
        switch result.1 {
        case .success(let output):
            var record = turn.steps[stepIndex].toolCalls[callIndex]
            record.status = output.isError ? .failed : .done
            record.summary = output.summary
            record.detail = output.detail
            record.result = Self.capped(output.forModel)
            record.finishedAt = Date()
            if output.billedCost > 0 { record.billedCost = output.billedCost }
            turn.steps[stepIndex].toolCalls[callIndex] = record
            if !output.generatedImages.isEmpty {
                turn.steps[stepIndex].generatedImages = (turn.steps[stepIndex].generatedImages ?? []) + output.generatedImages
            }
            if !output.isError, callIndex < turn.steps[stepIndex].toolCalls.count {
                if record.name == "add_memory", !turn.notices.contains("Saved a memory: \(output.detail ?? output.summary)") {
                    turn.notices.append("Saved a memory: \(output.detail ?? output.summary)")
                } else if record.name == "edit_memory", !turn.notices.contains("Updated a memory: \(output.detail ?? output.summary)") {
                    turn.notices.append("Updated a memory: \(output.detail ?? output.summary)")
                }
            }
        case .failure(let error):
            let base = turn.steps[stepIndex].toolCalls[callIndex].summary.replacingOccurrences(of: "…", with: "")
            let message: String
            if let input = error as? ToolInputError {
                message = input.message
            } else if let github = error as? GitHubAPIError {
                message = github.isRateLimited ? "GitHub's hourly request limit was reached. Try again later." : github.description
            } else {
                message = ErrorExplainer.explain(error).message
            }
            fail(stepIndex, callIndex, message: "Error: \(message)", summary: "\(base) · didn't work", detail: message)
        }
    }

    mutating func fail(_ stepIndex: Int, _ callIndex: Int, message: String, summary: String, detail: String? = nil) {
        turn.steps[stepIndex].toolCalls[callIndex].status = .failed
        turn.steps[stepIndex].toolCalls[callIndex].result = message
        turn.steps[stepIndex].toolCalls[callIndex].summary = summary
        turn.steps[stepIndex].toolCalls[callIndex].detail = detail ?? message
        turn.steps[stepIndex].toolCalls[callIndex].finishedAt = Date()
    }

    static func capped(_ text: String, limit: Int = 80_000) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "\n[Cut off: the rest was too long. Ask for a smaller part.]"
    }

    // MARK: Errors in words

    static func describe(_ error: Error) -> TurnFailure {
        if let api = error as? OpenRouterAPIError {
            switch api.kind {
            case .outOfCredits:
                return TurnFailure(kind: .outOfCredits, message: "Your OpenRouter credit has run out.", detail: api.description)
            case .spendingCapReached:
                return TurnFailure(kind: .outOfCredits, message: "This OpenRouter key has reached its spending limit.", detail: api.description)
            case .freeDailyLimit:
                return TurnFailure(kind: .freeLimitReached, message: "You've used today's free AI requests. They come back at midnight UTC (8 PM Eastern in summer, 7 PM in winter).", detail: api.description)
            case .rateLimited, .busyRetrySoon:
                return TurnFailure(kind: .providerFailed, message: "The AI is busy right now. Try again in a minute.", detail: api.description)
            case .invalidKey:
                return TurnFailure(kind: .signInNeeded, message: "OpenRouter didn't accept the sign-in. Sign in again in Settings.", detail: api.description)
            case .contextTooLong:
                return TurnFailure(kind: .tooLong, message: "This chat is too long for this AI. Start a new chat, or pick an AI that can hold more.", detail: api.description)
            case .noModelAvailable:
                return TurnFailure(kind: .providerFailed, message: "No AI could take this request just now. Try again, or pick another AI.", detail: api.description)
            case .providerFailed:
                return TurnFailure(kind: .providerFailed, message: "The AI's service had a problem partway through. Try again.", detail: api.description)
            case .moderated:
                return TurnFailure(kind: .other, message: "The AI's provider refused this request.", detail: api.description)
            case .appRestricted:
                return TurnFailure(kind: .other, message: "OpenRouter only lets certain listed apps use this AI, so MAIPA-G can't. It's now hidden from the AI picker. Pick another AI, or Auto, and try again.", detail: api.description)
            case .badRequest, .other:
                let explanation = ErrorExplainer.explain(api)
                return TurnFailure(kind: .other, message: explanation.message, detail: api.description)
            }
        }
        if let http = error as? HTTPError {
            let explanation = ErrorExplainer.explain(http)
            if http.isOffline { return TurnFailure(kind: .offline, message: explanation.message, detail: http.description) }
            return TurnFailure(kind: .providerFailed, message: explanation.message, detail: http.description)
        }
        let explanation = ErrorExplainer.explain(error)
        return TurnFailure(kind: .other, message: explanation.message, detail: explanation.technical)
    }
}
