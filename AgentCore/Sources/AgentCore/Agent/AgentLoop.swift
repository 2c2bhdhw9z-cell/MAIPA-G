import Foundation

public struct BackgroundSubagentCardPatch: Sendable {
    public var callID: String
    public var update: ToolLiveUpdate

    public init(callID: String, update: ToolLiveUpdate) {
        self.callID = callID
        self.update = update
    }
}

/// Thread-safe inbox for live mid-run steering instructions and backgrounded sub-agent completions
/// sent while an agent turn is running.
public actor SteeringInbox {
    private var pendingMessages: [String] = []
    private var completedBackgroundReports: [String] = []
    private var pendingCardPatches: [BackgroundSubagentCardPatch] = []
    private var backgroundTasks: [UUID: Task<Void, Never>] = [:]
    private var steerWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var activityWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var activityTimers: [UUID: Task<Void, Never>] = [:]
    private var timedOutActivityWaiters: Set<UUID> = []
    /// Helpers whose completion arrived before they were registered here.
    private var finishedBeforeRegistration: Set<UUID> = []
    private var yieldAfterStep = false

    public init() {}

    public func enqueue(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        pendingMessages.append(trimmed)
        wakeSteerWaiters()
        wakeActivityWaiters()
    }

    public func drain() -> [String] {
        guard !pendingMessages.isEmpty else { return [] }
        let items = pendingMessages
        pendingMessages.removeAll()
        return items
    }

    public func peek() -> [String] {
        pendingMessages
    }

    public func hasPendingSteer() -> Bool {
        !pendingMessages.isEmpty || yieldAfterStep
    }

    public func removeFirst(matching text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let index = pendingMessages.firstIndex(of: trimmed) else { return false }
        pendingMessages.remove(at: index)
        return true
    }

    public func requestYieldAfterStep() {
        yieldAfterStep = true
        wakeSteerWaiters()
        wakeActivityWaiters()
    }

    public func shouldYieldAfterStep() -> Bool {
        yieldAfterStep
    }

    /// Suspends until a live user steering note (or graceful yield) arrives, or returns immediately if one is already waiting.
    public func waitForSteer() async {
        if hasPendingSteer() || Task.isCancelled { return }
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                if hasPendingSteer() || Task.isCancelled {
                    cont.resume()
                } else {
                    steerWaiters[id] = cont
                }
            }
        } onCancel: {
            Task { await self.cancelSteerWaiter(id) }
        }
    }

    private func cancelSteerWaiter(_ id: UUID) {
        steerWaiters.removeValue(forKey: id)?.resume()
    }

    public func registerBackgroundTask(_ id: UUID, task: Task<Void, Never>) {
        // A helper can finish between being detached and being registered here (two separate
        // awaits in AgentExecutor). Its completion already arrived, so registering it now would
        // leave a task that never completes, and the turn would wait on it forever.
        if finishedBeforeRegistration.remove(id) != nil { return }
        backgroundTasks[id] = task
    }

    public func recordBackgroundCardPatch(_ patch: BackgroundSubagentCardPatch) {
        if let idx = pendingCardPatches.firstIndex(where: { $0.callID == patch.callID }) {
            pendingCardPatches[idx] = patch
        } else {
            pendingCardPatches.append(patch)
        }
        wakeActivityWaiters()
    }

    public func completeBackgroundTask(
        _ id: UUID,
        report: String?,
        finalPatch: BackgroundSubagentCardPatch?
    ) {
        if backgroundTasks.removeValue(forKey: id) == nil {
            finishedBeforeRegistration.insert(id)
        }
        if let finalPatch {
            if let idx = pendingCardPatches.firstIndex(where: { $0.callID == finalPatch.callID }) {
                pendingCardPatches[idx] = finalPatch
            } else {
                pendingCardPatches.append(finalPatch)
            }
        }
        if let report, !report.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            completedBackgroundReports.append(report)
        }
        wakeActivityWaiters()
    }

    public func activeBackgroundTaskCount() -> Int {
        backgroundTasks.count
    }

    public func drainBackgroundReports() -> [String] {
        guard !completedBackgroundReports.isEmpty else { return [] }
        let items = completedBackgroundReports
        completedBackgroundReports.removeAll()
        return items
    }

    public func drainCardPatches() -> [BackgroundSubagentCardPatch] {
        guard !pendingCardPatches.isEmpty else { return [] }
        let items = pendingCardPatches
        pendingCardPatches.removeAll()
        return items
    }

    public func cancelAllBackgroundTasks() {
        yieldAfterStep = false
        let tasks = Array(backgroundTasks.values)
        backgroundTasks.removeAll()
        for t in tasks { t.cancel() }
        wakeSteerWaiters()
        wakeActivityWaiters()
    }

    public func clearYieldFlag() {
        yieldAfterStep = false
    }

    /// Waits while backgrounded sub-agents are still working until a live steer, card patch, or completion arrives.
    /// A "finish after this step" flag does not wake this: the main agent stays here until the helpers actually finish.
    ///
    /// With a `timeout`, gives up after that many seconds with nothing arriving and returns false,
    /// so a helper that went quiet can't hold the reply on "Thinking…" forever. Returns true otherwise.
    @discardableResult
    public func waitForActivity(timeout: TimeInterval? = nil) async -> Bool {
        if !pendingMessages.isEmpty || !completedBackgroundReports.isEmpty || !pendingCardPatches.isEmpty || backgroundTasks.isEmpty || Task.isCancelled {
            return true
        }
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                if !pendingMessages.isEmpty || !completedBackgroundReports.isEmpty || !pendingCardPatches.isEmpty || backgroundTasks.isEmpty || Task.isCancelled {
                    cont.resume()
                } else {
                    activityWaiters[id] = cont
                    if let timeout {
                        activityTimers[id] = Task { [weak self] in
                            try? await Task.sleep(nanoseconds: UInt64(max(timeout, 0) * 1_000_000_000))
                            if Task.isCancelled { return }
                            await self?.timeOutActivityWaiter(id)
                        }
                    }
                }
            }
        } onCancel: {
            Task { await self.cancelActivityWaiter(id) }
        }
        activityTimers.removeValue(forKey: id)?.cancel()
        return timedOutActivityWaiters.remove(id) == nil
    }

    private func cancelActivityWaiter(_ id: UUID) {
        activityWaiters.removeValue(forKey: id)?.resume()
    }

    private func timeOutActivityWaiter(_ id: UUID) {
        guard let waiter = activityWaiters.removeValue(forKey: id) else { return }
        timedOutActivityWaiters.insert(id)
        waiter.resume()
    }

    private func wakeSteerWaiters() {
        let waiters = Array(steerWaiters.values)
        steerWaiters.removeAll()
        for w in waiters { w.resume() }
    }

    private func wakeActivityWaiters() {
        let waiters = Array(activityWaiters.values)
        activityWaiters.removeAll()
        for w in waiters { w.resume() }
    }
}

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
    /// Optional live steering inbox so the user can redirect a running turn between steps.
    public var steering: SteeringInbox?
    /// False for background sub-agents and workflow steps that run autonomously without pausing for interactive questions.
    public var allowAskUser: Bool
    /// Tools just run, the way Kiro runs commands without asking (owner, 11 November 2026: "You
    /// don't ask to run commands"). Only something that can't be undone at all still asks.
    public var autoApprove: Bool
    /// When every tool in a step is one of these and worked, the reply ends there: the picture
    /// is the answer, and another model call only added 10 to 20 seconds.
    public var endAfterTools: Set<String>
    /// Set when the person tapped Retry on a reply that stopped early. The turn carries on from
    /// where it stopped, and the model is told plainly that it was cut off. Not saved in the chat.
    public var resumeNote: String?

    public init(chat: Chat, route: Route, systemPrompt: String, tools: [any AgentTool], allowTools: Bool = true, maxSteps: Int = 250, spendLimit: Double? = nil, attachmentData: [UUID: Data] = [:], serverTools: [ToolSpec] = [], fallbackModels: [String] = [], requiresInitialSpendApproval: Bool = false, agent: AgentDefinition? = nil, steering: SteeringInbox? = nil, allowAskUser: Bool = true, resumeNote: String? = nil, autoApprove: Bool = false) {
        self.autoApprove = autoApprove
        self.endAfterTools = []
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
        self.steering = steering
        self.allowAskUser = allowAskUser
        self.resumeNote = resumeNote
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
    /// Saves inline images streamed directly by multimodal image-generating chat models (`choices[0].message.images`).
    public var saveInlineGeneratedImage: (@Sendable (_ data: Data, _ mimeType: String, _ prompt: String, _ model: String) async -> GeneratedImageResult?)?
    /// Longest a model request may go with nothing at all arriving (keep-alives don't count)
    /// before the step ends with the early-stop notice instead of sitting on "Thinking…".
    public var modelSilenceLimit: TimeInterval = 300
    /// Longest the turn waits on background sub-agents that send nothing at all before it stops
    /// them and answers with what it has.
    public var backgroundHelperSilenceLimit: TimeInterval = 600
    /// Longest one tool call may go without any output or progress before it is stopped and
    /// reported as failed. A tool that keeps reporting progress is never cut off, however long it
    /// runs. Tools that run other agents (`toolTimeLimitExempt`) are exempt: each of their own
    /// steps has these limits.
    public var toolTimeLimit: TimeInterval = 1_200

    public init(
        openRouter: OpenRouterClient,
        freeRoute: @escaping @Sendable () -> Route,
        onOutOfCredits: @escaping @Sendable () async -> Void,
        saveInlineGeneratedImage: (@Sendable (_ data: Data, _ mimeType: String, _ prompt: String, _ model: String) async -> GeneratedImageResult?)? = nil
    ) {
        self.openRouter = openRouter
        self.freeRoute = freeRoute
        self.onOutOfCredits = onOutOfCredits
        self.saveInlineGeneratedImage = saveInlineGeneratedImage
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
    private let steering: SteeringInbox

    init(events: AsyncStream<AgentEvent>, task: Task<Void, Never>, steering: SteeringInbox) {
        self.events = events
        self.task = task
        self.steering = steering
    }

    public func cancel() {
        task.cancel()
        let inbox = steering
        Task { await inbox.cancelAllBackgroundTasks() }
    }

    /// Injects a live mid-run steering note into the running turn at the next step boundary.
    public func steer(_ message: String) async {
        await steering.enqueue(message)
    }

    /// Cancels a pending unconsumed steering note before the next step boundary consumes it.
    public func removeSteering(_ message: String) async -> Bool {
        await steering.removeFirst(matching: message)
    }

    /// Drains any steering notes that arrived right as the turn finished so the session can continue immediately (`KiroCrew#20549`).
    public func drainUnconsumedSteering() async -> [String] {
        await steering.drain()
    }

    /// Gracefully finishes the current step/tools without killing an in-flight tool command, then ends the run so a chronological user message can continue immediately.
    public func finishAfterCurrentStep() async {
        await steering.requestYieldAfterStep()
    }
}

/// The agent loop: ask the model, run the tools it asks for, give it the results, and repeat
/// until it answers, needs the user, or is stopped.
public enum AgentLoop {
    public static func start(_ input: AgentTurnInput, environment: AgentEnvironment) -> AgentRun {
        // Every event carries the whole turn, so if the reader falls behind, dropping older ones
        // loses nothing.
        let steering = input.steering ?? SteeringInbox()
        var effectiveInput = input
        effectiveInput.steering = steering
        let (events, continuation) = AsyncStream<AgentEvent>.makeStream(bufferingPolicy: .bufferingNewest(256))
        let task = Task {
            var runner = Runner(input: effectiveInput, environment: environment, continuation: continuation)
            await runner.run()
            continuation.finish()
        }
        continuation.onTermination = { reason in
            if case .cancelled = reason { task.cancel() }
        }
        return AgentRun(events: events, task: task, steering: steering)
    }

    public static func run(_ input: AgentTurnInput, environment: AgentEnvironment) -> AsyncStream<AgentEvent> {
        start(input, environment: environment).events
    }

    /// The plain words a failed turn shows for `error`.
    static func describe(_ error: Error) -> TurnFailure { Runner.describe(error) }

    /// The notice on any reply that ended some way other than a normal finish.
    public static let stoppedEarlyNotice = "This reply stopped early. Tap retry. Retry carries on from where it stopped; staged file changes are kept, but the AI's own thinking and file reads from this attempt are lost."

    /// What the model is told when Retry carries on a reply that stopped early. Different from
    /// "Keep going", which is the person's own message asking for more.
    /// Whether a reply did anything worth keeping: wrote something or ran a tool.
    public static func didWork(_ steps: [AssistantStep]) -> Bool {
        steps.contains { !$0.toolCalls.isEmpty || !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !($0.generatedImages ?? []).isEmpty }
    }

    public static func resumeNote(partialText: String) -> String {
        let tail = String(partialText.suffix(600)).trimmingCharacters(in: .whitespacesAndNewlines)
        let whereItStopped = tail.isEmpty
            ? "It stopped before writing any visible reply."
            : "It stopped here: \"…\(tail)\""
        return "[Retry after an early stop] Your previous attempt at this reply was cut off before it finished (the connection or stream ended early), not stopped by the person. \(whereItStopped) Carry on from exactly where it stopped. Do not start over and do not repeat what you already wrote. Your earlier thinking and any file reads from that attempt were lost, so re-read a file only if you need it."
    }

    /// One plain line saying where a slow reply's time went, from the measured step timings.
    static func slowTurnSummary(elapsed: TimeInterval, steps: ArraySlice<AssistantStep>) -> String {
        func time(_ seconds: Double) -> String {
            let total = Int(seconds.rounded())
            return total >= 60 ? "\(total / 60)m \(total % 60)s" : "\(total)s"
        }
        let timings = steps.compactMap(\.timing)
        let calls = timings.filter { $0.modelCallSeconds > 0 }
        let modelTime = calls.reduce(0) { $0 + $1.modelCallSeconds }
        let firstBytes = calls.compactMap(\.firstByteSeconds)
        let averageFirst = firstBytes.isEmpty ? 0 : firstBytes.reduce(0, +) / Double(firstBytes.count)
        let slowestFirst = firstBytes.max() ?? 0
        let longestStall = calls.map(\.longestStallSeconds).max() ?? 0
        let toolTime = timings.compactMap(\.toolSeconds).reduce(0, +)
        let waiting = timings.compactMap(\.waitingSeconds).reduce(0, +)
        let retryWait = timings.reduce(0) { $0 + $1.retryWaitSeconds }
        let attempts = timings.reduce(0) { $0 + $1.attempts }
        let biggestPrompt = timings.map { $0.promptTokens ?? $0.sentTokensEstimate }.max() ?? 0
        return "Slow reply (\(time(elapsed))), measured: \(calls.count) model call\(calls.count == 1 ? "" : "s") took \(time(modelTime)) (first words after \(time(averageFirst)) on average, slowest \(time(slowestFirst)); longest silence mid-reply \(time(longestStall))). Tools \(time(toolTime)). Waiting on sub-agents \(time(waiting)). Retry waits \(time(retryWait)) over \(attempts) request\(attempts == 1 ? "" : "s"). Largest prompt \(biggestPrompt) tokens."
    }

    /// Tools that run other agents. Each of their agents' own model calls and tools has its own
    /// limits, so a wall-clock limit on the whole tool would only cut off healthy long work.
    static let toolTimeLimitExempt: Set<String> = ["launch_helpers", "invoke_sub_agent", "run_workflow"]

    /// Runs `work`, but returns as soon as the task is stopped or `seconds` pass (0 means no time
    /// limit), even when the work itself ignores cancellation: it is cancelled and left to wind
    /// down on its own, so a tool that never checks for Stop can't keep the reply running.
    /// With `activity`, the limit counts from the last `activity.touch()` instead of the start, so
    /// work that keeps reporting progress is never cut off.
    public static func bounded<T: Sendable>(seconds: TimeInterval, label: String, activity: ActivityClock? = nil, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        let gate = OneShot<T>()
        let worker = Task {
            do { gate.resume(.success(try await work())) } catch { gate.resume(.failure(error)) }
        }
        let timer: Task<Void, Never>? = seconds > 0 && seconds.isFinite ? Task {
            var wait = seconds
            while true {
                try? await Task.sleep(nanoseconds: UInt64(max(wait, 0.01) * 1_000_000_000))
                if Task.isCancelled { return }
                guard let activity else { break }
                let quiet = activity.secondsSinceLastActivity()
                if quiet >= seconds { break }
                wait = seconds - quiet
            }
            gate.resume(.failure(ToolTimedOut(tool: label, seconds: seconds, sinceLastActivity: activity != nil)))
            worker.cancel()
        } : nil
        defer { timer?.cancel() }
        return try await withTaskCancellationHandler {
            try await gate.wait()
        } onCancel: {
            gate.resume(.failure(CancellationError()))
            worker.cancel()
        }
    }

    /// "5 minutes", "1 minute", "45 seconds".
    static func spokenDuration(_ seconds: TimeInterval) -> String {
        if seconds >= 60 {
            let minutes = Int((seconds / 60).rounded())
            return "\(minutes) minute\(minutes == 1 ? "" : "s")"
        }
        let whole = max(Int(seconds.rounded()), 1)
        return "\(whole) second\(whole == 1 ? "" : "s")"
    }

    /// True for the ways a reply normally ends. "length" has its own notice.
    static func isNormalFinish(_ reason: String?) -> Bool {
        guard let reason = reason?.lowercased() else { return false }
        return ["stop", "tool_calls", "function_call", "end_turn", "length", "max_tokens", "stop_sequence", "tool_use"].contains(reason)
    }
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
    var fallbackModels: [String]
    let requiresInitialSpendApproval: Bool
    let steering: SteeringInbox?
    /// False for sub-agents, workflow steps and background helpers, which can never show a person
    /// an approval prompt. A tool needing one must fail honestly instead of parking forever.
    let allowAskUser: Bool
    let autoApprove: Bool
    let endAfterTools: Set<String>
    let environment: AgentEnvironment
    let continuation: AsyncStream<AgentEvent>.Continuation
    var maxPayloadBytes = Transcript.defaultMaxPayloadBytes
    var switchedToFree = false
    var autoContinuedBlankReply = false
    var injectedSteeringNotes: [String] = []
    var pendingBackgroundReports: [String] = []
    var pendingBlankReplyNudge: String?
    var toolInlineImages: [String: [ToolInlineImage]] = [:]
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
            if AIProviderModelID.decode(input.route.model) != nil,
               input.serverTools.contains(where: { $0.type == "openrouter:web_search" }) {
                for extraTool: any AgentTool in [WebSearchTool(transport: environment.openRouter.transport), ReadWebPageTool(transport: environment.openRouter.transport)]
                where byName[extraTool.name] == nil && (input.agent?.permits(tool: extraTool.name) ?? true) {
                    byName[extraTool.name] = extraTool
                    localSpecs.append(extraTool.spec)
                }
            }
        }
        tools = byName
        let serverSpecs = input.serverTools.filter { input.agent?.permits(tool: $0.function.name) ?? true }
        let mayAsk = input.allowAskUser && (input.agent?.permits(tool: AskUserTool.name) ?? true)
        specs = input.allowTools ? localSpecs + serverSpecs + (mayAsk ? [AskUserTool.spec] : []) : []
        maxSteps = input.maxSteps
        spendLimit = input.spendLimit.flatMap { $0 > 0 ? $0 : nil }
        attachmentData = input.attachmentData
        fallbackModels = input.fallbackModels.filter { $0 != input.route.model }
        requiresInitialSpendApproval = input.requiresInitialSpendApproval
        steering = input.steering
        allowAskUser = input.allowAskUser
        autoApprove = input.autoApprove
        endAfterTools = input.endAfterTools
        self.environment = environment
        self.continuation = continuation
        if let note = input.resumeNote {
            pendingBlankReplyNudge = note
            turn.stoppedEarly = nil
            turn.notices.removeAll { $0 == AgentLoop.stoppedEarlyNotice }
        }
    }

    /// A later step that finished normally means the reply did not stop early after all.
    mutating func clearStoppedEarly() {
        guard turn.stoppedEarly == true else { return }
        turn.stoppedEarly = nil
        turn.notices.removeAll { $0 == AgentLoop.stoppedEarlyNotice }
    }

    mutating func markStoppedEarly() {
        turn.stoppedEarly = true
        if !turn.notices.contains(AgentLoop.stoppedEarlyNotice) { turn.notices.append(AgentLoop.stoppedEarlyNotice) }
    }

    /// Background sub-agents sent nothing for the whole wait: stop them, and tell both the person
    /// and the model, so the turn answers with what it has instead of waiting forever.
    mutating func stopSilentBackgroundHelpers() async {
        await steering?.cancelAllBackgroundTasks()
        let span = AgentLoop.spokenDuration(environment.backgroundHelperSilenceLimit)
        turn.notices.append("Background sub-agents sent nothing for \(span), so I stopped them and carried on with what they had reported.")
        pendingBackgroundReports.append("[Background sub-agents stopped] The background sub-agents that were still running sent nothing for \(span), so the app stopped them and their work did not finish. Answer the person now with what you have, and say plainly which parts are missing.")
        emit(milestone: true)
    }

    /// Adds measured seconds to one of a step's timings (the last step when `index` is nil).
    mutating func addTiming(_ key: WritableKeyPath<StepTiming, Double?>, since start: Date, step index: Int? = nil) {
        guard let index = index ?? turn.steps.indices.last, turn.steps.indices.contains(index) else { return }
        var timing = turn.steps[index].timing ?? StepTiming()
        timing[keyPath: key] = (timing[keyPath: key] ?? 0) + Date().timeIntervalSince(start)
        turn.steps[index].timing = timing
    }


    mutating func emit(milestone: Bool) {
        chat.messages[chat.messages.count - 1].assistantTurn = turn
        continuation.yield(.updated(turn, milestone: milestone))
        lastEmit = Date()
    }

    mutating func applyBackgroundCardPatches() async {
        guard let patches = await steering?.drainCardPatches(), !patches.isEmpty else { return }
        var changed = false
        for patch in patches {
            for sIdx in turn.steps.indices {
                if let cIdx = turn.steps[sIdx].toolCalls.firstIndex(where: { $0.id == patch.callID }) {
                    turn.steps[sIdx].toolCalls[cIdx].summary = patch.update.summary
                    if let detail = patch.update.detail {
                        turn.steps[sIdx].toolCalls[cIdx].detail = detail
                    }
                    if let subs = patch.update.subagents {
                        let wasRunning = turn.steps[sIdx].toolCalls[cIdx].subagents?.contains { $0.status == .running } == true
                        turn.steps[sIdx].toolCalls[cIdx].subagents = subs
                        if wasRunning, !subs.contains(where: { $0.status == .running }) {
                            turn.steps[sIdx].toolCalls[cIdx].result = Self.capped(patch.update.detail ?? patch.update.summary)
                        }
                    }
                    if patch.update.billedCost > 0 {
                        turn.steps[sIdx].toolCalls[cIdx].billedCost = patch.update.billedCost
                    }
                    changed = true
                }
            }
        }
        if changed {
            emit(milestone: false)
        }
    }

    mutating func run() async {
        turn.status = .running
        turn.failure = nil
        turn.spendCheck = nil
        if turn.routeLabel == nil { turn.routeLabel = route.label }
        emit(milestone: true)
        var newSteps = 0
        let runStartedAt = Date()
        let firstStepOfRun = turn.steps.count
        do {
            while true {
                try Task.checkCancellation()
                await applyBackgroundCardPatches()
                if let last = turn.steps.indices.last, turn.steps[last].toolCalls.contains(where: { $0.result == nil }) {
                    let toolsStartedAt = Date()
                    let waitingForUser = try await runTools(inStep: last)
                    addTiming(\.toolSeconds, since: toolsStartedAt, step: last)
                    if waitingForUser {
                        turn.status = .waitingForUser
                        break
                    }
                    let calls = turn.steps[last].toolCalls
                    if !endAfterTools.isEmpty, !calls.isEmpty, calls.allSatisfy({ endAfterTools.contains($0.name) && $0.status == .done }),
                       !(await steering?.hasPendingSteer() ?? false) {
                        if turn.steps[last].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            turn.steps[last].text = calls.count == 1 ? calls[0].summary + "." : "Done."
                        }
                        turn.steps[last].finishedAt = turn.steps[last].finishedAt ?? Date()
                        clearStoppedEarly()
                        turn.status = .done
                        break
                    }
                    continue
                }
                if let incoming = await steering?.drain(), !incoming.isEmpty {
                    injectedSteeringNotes.append(contentsOf: incoming)
                    for note in incoming {
                        let preview = note.count > 120 ? String(note.prefix(120)) + "…" : note
                        turn.notices.append("Steered mid-run: \(preview)")
                    }
                    emit(milestone: false)
                }
                if let completedReports = await steering?.drainBackgroundReports(), !completedReports.isEmpty {
                    pendingBackgroundReports.append(contentsOf: completedReports)
                    await applyBackgroundCardPatches()
                }
                // Helpers that are still working must finish before the next model step.
                // A steer is kept and sent with their reports. It must not start a new
                // reply, or another helper, while they are running.
                if (await steering?.activeBackgroundTaskCount() ?? 0) > 0 {
                    let waitStartedAt = Date()
                    let heardBack = await steering?.waitForActivity(timeout: environment.backgroundHelperSilenceLimit)
                    addTiming(\.waitingSeconds, since: waitStartedAt)
                    if heardBack == false { await stopSilentBackgroundHelpers() }
                    continue
                }
                if injectedSteeringNotes.isEmpty, pendingBackgroundReports.isEmpty, newSteps > 0, await steering?.shouldYieldAfterStep() == true {
                    turn.status = .done
                    break
                }
                if pendingBlankReplyNudge == nil, let last = turn.steps.last, last.toolCalls.isEmpty, last.finishedAt != nil {
                    // If the user sent a live mid-run steering note or a backgrounded sub-agent completed, continue immediately!
                    if !injectedSteeringNotes.isEmpty || !pendingBackgroundReports.isEmpty {
                        // Fall through to next step with `injectedSteeringNotes` / `pendingBackgroundReports`.
                    } else if (await steering?.activeBackgroundTaskCount() ?? 0) > 0 {
                        let waitStartedAt = Date()
                        let heardBack = await steering?.waitForActivity(timeout: environment.backgroundHelperSilenceLimit)
                        addTiming(\.waitingSeconds, since: waitStartedAt)
                        if heardBack == false { await stopSilentBackgroundHelpers() }
                        await applyBackgroundCardPatches()
                        continue
                    } else {
                        let visibleText = last.text.trimmingCharacters(in: .whitespacesAndNewlines)
                        let hasGeneratedImages = !(last.generatedImages ?? []).isEmpty
                        if visibleText.isEmpty && !hasGeneratedImages && !autoContinuedBlankReply && newSteps < maxSteps {
                            autoContinuedBlankReply = true
                            pendingBlankReplyNudge = "You completed the previous step without writing a visible reply to the user. Now write your clear plain-language answer based on the tool outputs and findings above."
                        } else {
                            if visibleText.isEmpty && !hasGeneratedImages {
                                // Only thinking (or nothing) came back, even after the nudge.
                                // Ending as a plain "done" left a reply with no answer and no
                                // sign that anything went wrong.
                                markStoppedEarly()
                            }
                            turn.status = .done
                            break
                        }
                    }
                }
                guard newSteps < maxSteps else {
                    await steering?.cancelAllBackgroundTasks()
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
            await steering?.cancelAllBackgroundTasks()
            stopRunningTools(reason: "Stopped")
            turn.status = .stopped
        } catch {
            await steering?.cancelAllBackgroundTasks()
            stopRunningTools(reason: "Didn't finish")
            turn.status = .failed
            turn.failure = Self.describe(error)
            // An empty reply is an early stop too: say so, and let Retry carry on. So is any
            // failure after the reply already did work: Try again carries on from there instead
            // of starting over (11 November 2026: two hours of work were thrown away by one
            // dropped connection and a tap on Try again).
            if (error as? OpenRouterAPIError)?.code == "empty_reply" || AgentLoop.didWork(turn.steps) { markStoppedEarly() }
            if let api = error as? OpenRouterAPIError, api.kind == .appRestricted {
                await environment.onModelRestricted(route.model)
            }
        }
        if Task.isCancelled, turn.status == .running { turn.status = .stopped }
        // Measured, not guessed: a slow reply says where its time went, so the cause is evidence.
        let elapsed = Date().timeIntervalSince(runStartedAt)
        if elapsed >= Self.slowTurnSeconds, firstStepOfRun < turn.steps.count {
            turn.notices.removeAll { $0.hasPrefix("Slow reply (") }
            turn.notices.append(AgentLoop.slowTurnSummary(elapsed: elapsed, steps: turn.steps[firstStepOfRun...]))
        }
        await steering?.clearYieldFlag()
        emit(milestone: true)
    }

    /// A reply that runs at least this long gets a measured "where the time went" note.
    static let slowTurnSeconds: TimeInterval = 120

    mutating func stopRunningTools(reason: String) {
        let isGracefulStop = (reason == "Stopped")
        for stepIndex in turn.steps.indices {
            for callIndex in turn.steps[stepIndex].toolCalls.indices {
                let recordSnapshot = turn.steps[stepIndex].toolCalls[callIndex]
                let hasRunningSubagents = recordSnapshot.subagents?.contains(where: { $0.status == .running }) == true
                guard recordSnapshot.status == .running || hasRunningSubagents else { continue }
                var record = recordSnapshot
                if record.status == .running {
                    record.status = isGracefulStop ? .done : .failed
                }
                if record.detail == nil || record.detail?.isEmpty == true {
                    record.detail = reason
                }
                let baseSummary = record.summary.replacingOccurrences(of: "…", with: "").trimmingCharacters(in: .whitespaces)
                if isGracefulStop, !baseSummary.lowercased().contains("stopped") {
                    record.summary = baseSummary.isEmpty ? "Stopped" : "\(baseSummary) · stopped"
                }
                if var subs = record.subagents {
                    for idx in subs.indices where subs[idx].status == .running {
                        subs[idx].status = .cancelled
                        subs[idx].latestActivity = "Stopped"
                    }
                    record.subagents = subs
                } else if SubagentTools.isSubagentTool(record.name) {
                    record.subagents = SubagentRunItem.resolvedItems(for: record).map { item in
                        var copy = item
                        if copy.status == .running {
                            copy.status = .cancelled
                            copy.latestActivity = "Stopped"
                        }
                        return copy
                    }
                }
                if isGracefulStop, SubagentTools.isSubagentTool(record.name), record.result == nil {
                    let actionsDone = (record.subagents ?? []).reduce(0) { $0 + $1.toolCallCount }
                    let progressNote = actionsDone > 0 ? " after \(actionsDone) actions of partial progress" : ""
                    record.result = "Paused/stopped before completion\(progressNote) (not a tool failure). Sub-agent launching works normally — launch sub-agents in parallel when continuing."
                }
                if record.finishedAt == nil {
                    record.finishedAt = Date()
                }
                turn.steps[stepIndex].toolCalls[callIndex] = record
            }
            if turn.steps[stepIndex].finishedAt == nil { turn.steps[stepIndex].finishedAt = Date() }
        }
    }

    // MARK: One request to the model

    mutating func requestStep() async throws {
        var attempt = 0
        var retryWaitSeconds: Double = 0
        let activeBlankNudge = pendingBlankReplyNudge
        pendingBlankReplyNudge = nil
        let activeSteeringNotes = injectedSteeringNotes
        injectedSteeringNotes.removeAll()
        let activeBackgroundReports = pendingBackgroundReports
        pendingBackgroundReports.removeAll()
        let stepSteered = activeSteeringNotes.isEmpty ? nil : activeSteeringNotes
        // Every provider an attempt at this step went to: a retry can switch provider (a
        // fallback, or the free AIs), and an attempt that failed partway may still have cost.
        var providersTried: [String] = []
        // Time this step's attempts have spent waiting with nothing at all arriving. It carries
        // over retries: a request whose connection times out (180 s) before the 5-minute watchdog
        // used to be retried with a fresh watchdog each time, so a provider that never answered
        // kept the reply on "Thinking…" for about nine minutes before anything was said.
        var silentSeconds: TimeInterval = 0
        while true {
            attempt += 1
            turn.steps.append(AssistantStep(steeredMessages: stepSteered))
            let index = turn.steps.count - 1
            let attemptProvider = AIProviderModelID.providerID(route.model)
            if !providersTried.contains(attemptProvider) { providersTried.append(attemptProvider) }
            turn.steps[index].providersTried = providersTried
            // Kept on the turn too: an attempt that failed with nothing to show is removed as a
            // step, but its provider may still have charged for it.
            if !(turn.providersTried ?? []).contains(attemptProvider) {
                turn.providersTried = (turn.providersTried ?? []) + [attemptProvider]
            }
            chat.messages[chat.messages.count - 1].assistantTurn = turn
            var rawMessages = Transcript.messages(
                for: chat,
                systemPrompt: systemPrompt,
                attachmentData: attachmentData,
                readsImages: route.readsImages,
                readsPDFs: route.readsPDFs,
                toolInlineImages: toolInlineImages
            )
            if !activeBackgroundReports.isEmpty {
                let stillRunning = await steering?.activeBackgroundTaskCount() ?? 0
                let tailNote = stillRunning > 0
                    ? "(\(stillRunning) other background sub-agent\(stillRunning == 1 ? " is" : "s are") still running. Do not answer the user and do not start more work until \(stillRunning == 1 ? "that report arrives" : "those reports arrive").)"
                    : "(All background sub-agents have now finished — synthesize the full findings clearly for the user.)"
                let heading = "[Background sub-agent report]\n\n"
                let footer = "\n\n" + tailNote
                let report = Transcript.cappedToolResult(
                    activeBackgroundReports.joined(separator: "\n\n---\n\n"),
                    limit: Transcript.maxToolResultCharacters - heading.count - footer.count
                )
                rawMessages.append(.user(heading + report + footer))
            }
            if let nudge = activeBlankNudge {
                rawMessages.append(.user(nudge))
            }
            let isExternalProvider = AIProviderModelID.decode(route.model) != nil
            var effectiveSpecs = specs
            if isExternalProvider {
                let hadOpenRouterWeb = effectiveSpecs.contains { $0.type == "openrouter:web_search" }
                effectiveSpecs.removeAll { $0.type.hasPrefix("openrouter:") }
                let ws = WebSearchTool(transport: environment.openRouter.transport)
                let fp = ReadWebPageTool(transport: environment.openRouter.transport)
                if hadOpenRouterWeb, !effectiveSpecs.contains(where: { $0.function.name == ws.name }) {
                    effectiveSpecs.append(contentsOf: [ws.spec, fp.spec])
                }
            }
            // Multimodal chat-image models (like `google/gemini-3.1-flash-image-preview` or `openai/gpt-5-image`)
            // emit `choices[0].message.images` when `modalities: ["image", "text"]` is set.
            let requestModalities: [String]? = (!isExternalProvider && route.generatesImages && effectiveSpecs.isEmpty)
                ? ["image", "text"]
                : nil
            let toolSchemaTokens = Transcript.estimatedToolTokens(effectiveSpecs)
            let messageBudget = max(4_096, route.contextBudget - toolSchemaTokens)
            let (messages, trimmed) = Transcript.fit(
                rawMessages,
                budget: messageBudget,
                maxPayloadBytes: maxPayloadBytes
            )
            let request = ChatCompletionRequest(
                model: route.model,
                // OpenRouter refuses the whole request (400) when this list, the chosen AI
                // included, has more than 3 entries.
                models: (isExternalProvider || fallbackModels.isEmpty) ? nil : Array(([route.model] + fallbackModels).prefix(ChatCompletionRequest.maxModels)),
                messages: messages,
                tools: effectiveSpecs,
                reasoningEffort: route.effort,
                plugins: isExternalProvider ? [] : route.plugins,
                sessionID: isExternalProvider ? nil : chat.id.uuidString,
                automaticCaching: isExternalProvider ? false : route.automaticCaching,
                modalities: requestModalities
            )
            if trimmed, !turn.notices.contains(Self.trimmedNotice) { turn.notices.append(Self.trimmedNotice) }

            var accumulator = StreamAccumulator()
            var emittedInitialStep = false
            let sentAt = Date()
            var firstByteAt: Date?
            var lastByteAt = sentAt
            var longestStall: Double = 0
            let sentTokensEstimate = Transcript.estimatedTokens(messages) + toolSchemaTokens
            func timing() -> StepTiming {
                StepTiming(
                    firstByteSeconds: firstByteAt.map { $0.timeIntervalSince(sentAt) },
                    modelCallSeconds: Date().timeIntervalSince(sentAt),
                    longestStallSeconds: longestStall,
                    retryWaitSeconds: retryWaitSeconds,
                    attempts: attempt,
                    promptTokens: accumulator.usage?.promptTokens,
                    sentTokensEstimate: sentTokensEstimate
                )
            }
            do {
                let openRouter = environment.openRouter
                let stream = SilenceWatchdog.watch(limit: max(0.05, environment.modelSilenceLimit - silentSeconds)) {
                    try await openRouter.stream(request)
                }
                for try await chunk in stream {
                    let arrivedAt = Date()
                    if firstByteAt == nil {
                        firstByteAt = arrivedAt
                    } else {
                        longestStall = max(longestStall, arrivedAt.timeIntervalSince(lastByteAt))
                    }
                    lastByteAt = arrivedAt
                    let prevToolCount = accumulator.toolCalls.count
                    accumulator.apply(chunk)
                    if let error = chunk.error { throw error }
                    let changed = turn.steps[index].text != accumulator.text
                        || turn.steps[index].reasoning != accumulator.reasoning
                        || accumulator.toolCalls.count != prevToolCount
                    if !accumulator.reasoning.isEmpty,
                       turn.steps[index].reasoningFinishedAt == nil,
                       (!accumulator.text.isEmpty || !accumulator.toolCalls.isEmpty) {
                        turn.steps[index].reasoningFinishedAt = Date()
                    }
                    turn.steps[index].text = accumulator.text
                    turn.steps[index].reasoning = accumulator.reasoning
                    if let model = accumulator.model { turn.steps[index].model = model }
                    turn.steps[index].provider = AIProviderModelID.providerID(route.model)
                    // Every new piece of text goes out at once, so words never wait for the next
                    // ones (a model can pause mid-reply). The app draws at most once a frame.
                    if changed || !emittedInitialStep {
                        emittedInitialStep = true
                        emit(milestone: false)
                    }
                }
                try Task.checkCancellation()
                guard accumulator.hasOutput || !accumulator.reasoning.isEmpty || accumulator.finishReason != nil else {
                    throw OpenRouterAPIError(httpStatus: 502, code: "empty_reply", message: "The AI sent back an empty reply.")
                }
                let measured = timing()
                await finish(step: index, with: accumulator)
                turn.steps[index].timing = measured
                if accumulator.finishReason == "length", accumulator.toolCalls.isEmpty {
                    turn.notices.append("This reply hit its length limit and may be cut off.")
                } else if accumulator.toolCalls.isEmpty, !AgentLoop.isNormalFinish(accumulator.finishReason) {
                    // The stream ended without the model saying it was done: a dropped connection
                    // or a server closing mid-reply. The text so far must not look finished.
                    markStoppedEarly()
                } else if accumulator.finishReason != "length",
                          !accumulator.toolCalls.isEmpty || !accumulator.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    // A normal finish with something in it: an earlier step's early stop (or a
                    // reasoning-only step before it) no longer describes this reply.
                    clearStoppedEarly()
                }
                emit(milestone: true)
                return
            } catch {
                let producedOutput = accumulator.hasOutput
                if producedOutput || error is CancellationError || Task.isCancelled {
                    // Keep what arrived; a half-written tool call is not safe to run, so drop those.
                    let measured = timing()
                    await finish(step: index, with: accumulator, keepToolCalls: false)
                    turn.steps[index].timing = measured
                    if producedOutput, !(error is CancellationError), !Task.isCancelled {
                        markStoppedEarly()
                    }
                    emit(milestone: true)
                    throw error
                }
                turn.steps.remove(at: index)
                if firstByteAt == nil {
                    silentSeconds += Date().timeIntervalSince(sentAt)
                } else {
                    // Something did arrive (thinking, say), so this attempt wasn't silence.
                    silentSeconds = 0
                }
                if error is ModelWentSilent || silentSeconds >= environment.modelSilenceLimit {
                    // Nothing came back at all. Waiting on, or quietly retrying, is how a reply sat
                    // on "Thinking…" for many minutes. End it with the notice; Retry carries on.
                    markStoppedEarly()
                    throw ModelWentSilent(seconds: max(silentSeconds, (error as? ModelWentSilent)?.seconds ?? 0))
                }
                switch await recovery(for: error, attempt: attempt) {
                case .retry(let delay):
                    retryWaitSeconds += delay
                    if delay >= 4 {
                        try await waitWithLiveCountdown(seconds: Int(delay.rounded(.up)))
                    } else if delay > 0 {
                        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    }
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
                    maxPayloadBytes = max(1_500_000, maxPayloadBytes / 2)
                    continue
                case .simplifyRequest:
                    if route.automaticCaching || !fallbackModels.isEmpty {
                        route.automaticCaching = false
                        fallbackModels = []
                    } else {
                        let msg = (error as? OpenRouterAPIError)?.message.lowercased() ?? ""
                        if msg.contains("effort") || msg.contains("reasoning") {
                            if route.effort == .xhigh || route.effort == .max {
                                route.effort = .high
                            } else {
                                route.effort = nil
                            }
                        } else {
                            throw error
                        }
                    }
                    continue
                case .giveUp:
                    throw error
                }
            }
        }
    }

    /// Waits out a temporary rate-limit (`429`) window up to 60 seconds with a live countdown notice
    /// that cleans itself up automatically once the retry resumes, so recovered retries leave zero warning clutter.
    private mutating func waitWithLiveCountdown(seconds totalSeconds: Int) async throws {
        let clamped = min(max(totalSeconds, 1), 60)
        let prefix = "Rate limit reached — retrying automatically in "
        defer {
            turn.notices.removeAll { $0.hasPrefix(prefix) }
            emit(milestone: false)
        }
        for remaining in stride(from: clamped, through: 1, by: -1) {
            try Task.checkCancellation()
            turn.notices.removeAll { $0.hasPrefix(prefix) }
            turn.notices.append("\(prefix)\(remaining)s…")
            emit(milestone: false)
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    mutating func finish(step index: Int, with accumulator: StreamAccumulator, keepToolCalls: Bool = true) async {
        var step = turn.steps[index]
        step.finishedAt = Date()
        step.text = accumulator.text
        step.reasoning = accumulator.reasoning
        step.reasoningDetails = accumulator.reasoningDetails
        step.model = accumulator.model ?? step.model
        step.provider = AIProviderModelID.providerID(route.model)
        if !fallbackModels.isEmpty,
           AIProviderModelID.decode(route.model) == nil,
           let actual = accumulator.model, actual != route.model,
           !turn.notices.contains(where: { $0.contains("switched to fallback AI") }) {
            turn.notices.append("OpenRouter switched to fallback AI \(actual) because the first AI was unavailable.")
        }
        step.usage = accumulator.usage
        step.finishReason = accumulator.finishReason
        step.citations = accumulator.citations.isEmpty ? nil : accumulator.citations
        if !accumulator.imageDataURLs.isEmpty, let saver = environment.saveInlineGeneratedImage {
            let promptText = chat.messages.reversed().compactMap { msg -> String? in
                if case .user(let u) = msg.body { return u.text }
                return nil
            }.first { !$0.isEmpty } ?? "Generated picture"
            var savedImages = step.generatedImages ?? []
            for rawURL in accumulator.imageDataURLs {
                let decoded = OpenRouterClient.decodeImagePayload(rawURL)
                if let bytes = decoded.data, !bytes.isEmpty,
                   let saved = await saver(bytes, decoded.mimeType ?? "image/png", promptText, accumulator.model ?? route.model) {
                    savedImages.append(saved)
                }
            }
            if !savedImages.isEmpty {
                step.generatedImages = savedImages
            }
        }
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

    enum Recovery { case retry(TimeInterval), switchToFree, shrinkContext, simplifyRequest, giveUp }

    func recovery(for error: Error, attempt: Int) async -> Recovery {
        if let api = error as? OpenRouterAPIError {
            if api.httpStatus == 413 && attempt <= 2 {
                return .shrinkContext
            }
            switch api.kind {
            case .outOfCredits where route.isAuto && !route.isFree && !switchedToFree:
                return .switchToFree
            case .busyRetrySoon where attempt <= 3:
                return .retry(min(api.retryAfter ?? 4, 30))
            case .rateLimited where attempt <= 3 && (api.retryAfter ?? 15) <= 65:
                let suggested = api.retryAfter ?? Double(attempt * 5)
                return .retry(min(max(suggested, 1), 60))
            case .providerFailed where attempt <= 2, .noModelAvailable where attempt <= 2:
                return .retry(Double(attempt) * 1.5)
            case .contextTooLong where attempt <= 2:
                return .shrinkContext
            case .badRequest where attempt <= 2 && (route.effort != nil || route.automaticCaching || !fallbackModels.isEmpty):
                return .simplifyRequest
            default:
                return .giveUp
            }
        }
        // A dropped connection is retried for about a minute (1, 2, 4, 8, 16 and 20 seconds), and
        // no signal at all for about two: a phone moving between Wi-Fi and cellular, or through a
        // dead spot, loses its connection for longer than a few seconds. Before 11 November 2026
        // it got two quick retries over three seconds, and the reply failed.
        if let http = error as? HTTPError, case .transport(_, let isOffline) = http {
            if !isOffline, attempt <= 6 { return .retry(Self.reconnectDelay(attempt: attempt)) }
            if isOffline, attempt <= 5 { return .retry(Self.offlineDelay(attempt: attempt)) }
        }
        return .giveUp
    }

    static func reconnectDelay(attempt: Int) -> TimeInterval { min(pow(2, Double(max(attempt, 1) - 1)), 20) }
    static func offlineDelay(attempt: Int) -> TimeInterval { [5, 10, 20, 30, 45][min(max(attempt, 1), 5) - 1] }

    static let trimmedNotice = "This chat is long, so some older tool results were left out of what the AI sees."

    // MARK: Tools

    /// Runs the step's unfinished tool calls, all at once. Returns true when the AI asked the user
    /// questions that still need answers.
    mutating func runTools(inStep stepIndex: Int) async throws -> Bool {
        var waiting = false
        var jobs: [(callIndex: Int, callID: String, tool: any AgentTool, arguments: JSONValue, approved: Bool, existingSubagents: [SubagentRunItem]?)] = []

        for callIndex in turn.steps[stepIndex].toolCalls.indices {
            let call = turn.steps[stepIndex].toolCalls[callIndex]
            guard call.result == nil else { continue }
            let repeatedFailures = turn.steps.prefix(stepIndex).flatMap(\.toolCalls).filter { prev in
                guard prev.name == call.name && prev.arguments == call.arguments && prev.status == .failed else { return false }
                return !Self.isTransientFailure(prev.result ?? "")
            }.count
            // Twice the same way is enough: the second failure already told the AI to find another
            // way, so a third identical try isn't run.
            if repeatedFailures >= 2 {
                fail(
                    stepIndex,
                    callIndex,
                    message: Self.thirdFailureMessage,
                    summary: "Stopped a repeated failing tool call"
                )
                continue
            }
            if call.name == AskUserTool.name {
                if let answers = call.questions?.answerText {
                    turn.steps[stepIndex].toolCalls[callIndex].result = Self.capped(answers)
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
            var autoApproved = false
            if call.questions == nil {
                pendingApproval = await tool.approvalRequest(for: arguments)
                if pendingApproval == nil, outsideContentSeen() {
                    pendingApproval = await tool.approvalAfterOutsideContent(for: arguments)
                }
                if pendingApproval != nil, autoApprove, !(await tool.alwaysAsks(for: arguments)) {
                    pendingApproval = nil
                    autoApproved = true
                }
            }
            if let questions = call.questions {
                guard let answer = questions.answers?.first else {
                    waiting = true
                    continue
                }
                let normalizedAnswer = answer.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let affirmativeReplies: Set<String> = ["yes", "y", "allow", "approve", "approved", "sure", "ok", "okay", "go ahead", "do it"]
                let allowed = (questions.questions.first?.options.first == answer) || affirmativeReplies.contains(normalizedAnswer)
                guard allowed else {
                    turn.steps[stepIndex].toolCalls[callIndex].result = "The person did not approve this change."
                    turn.steps[stepIndex].toolCalls[callIndex].status = .done
                    turn.steps[stepIndex].toolCalls[callIndex].summary = "Change not approved"
                    turn.steps[stepIndex].toolCalls[callIndex].finishedAt = Date()
                    continue
                }
                wasApproved = true
            } else if let approval = pendingApproval {
                // A turn that can never ask the person must never park waiting for them.
                //
                // Sub-agents, workflow steps and background helpers run with `allowAskUser` off,
                // because nobody is watching their card to tap Allow. Parking them on an approval
                // meant they sat until they were killed and then reported "failed" — which looked
                // like the work broke, when in truth it was never allowed to start. Say so plainly
                // instead, so the report names the real cause and the main agent can decide to ask.
                if !allowAskUser {
                    turn.steps[stepIndex].toolCalls[callIndex].result = "Not run: this step cannot ask for approval, and it needs it. \(approval.question)"
                    turn.steps[stepIndex].toolCalls[callIndex].status = .failed
                    turn.steps[stepIndex].toolCalls[callIndex].summary = "Needs a person's approval, which this step cannot ask for"
                    turn.steps[stepIndex].toolCalls[callIndex].finishedAt = Date()
                    continue
                }
                turn.steps[stepIndex].toolCalls[callIndex].questions = QuestionSet(questions: [
                    .init(text: approval.question, options: [approval.allowLabel, "Don't allow"]),
                ])
                turn.steps[stepIndex].toolCalls[callIndex].status = .waitingForUser
                turn.steps[stepIndex].toolCalls[callIndex].summary = "Needs your approval"
                waiting = true
                continue
            } else {
                wasApproved = autoApproved
            }
            let priorSubs = turn.steps[stepIndex].toolCalls[callIndex].subagents
            turn.steps[stepIndex].toolCalls[callIndex].status = .running
            turn.steps[stepIndex].toolCalls[callIndex].summary = tool.runningSummary(for: arguments)
            if let initialSubs = tool.initialSubagents(for: arguments, callID: call.id) {
                if let priorSubs, !priorSubs.isEmpty {
                    turn.steps[stepIndex].toolCalls[callIndex].subagents = initialSubs.enumerated().map { idx, fresh in
                        if priorSubs.indices.contains(idx), priorSubs[idx].status == .completed, !priorSubs[idx].output.isEmpty {
                            var preserved = priorSubs[idx]
                            preserved.id = fresh.id
                            return preserved
                        }
                        return fresh
                    }
                } else {
                    turn.steps[stepIndex].toolCalls[callIndex].subagents = initialSubs
                }
            }
            let resumeSubs = turn.steps[stepIndex].toolCalls[callIndex].subagents
            jobs.append((callIndex, call.id, tool, arguments, wasApproved, resumeSubs))
        }
        emit(milestone: true)

        if !jobs.isEmpty {
            enum ToolEvent: Sendable {
                case progress(Int, ToolLiveUpdate)
                case finished(Int, Result<ToolOutput, Error>)
            }
            let (events, sink) = AsyncStream<ToolEvent>.makeStream()
            let toolLimit = environment.toolTimeLimit
            try await withThrowingTaskGroup(of: Void.self) { group in
                for job in jobs {
                    group.addTask {
                        let result: Result<ToolOutput, Error>
                        do {
                            let output: ToolOutput
                            let tool = job.tool
                            let limit = AgentLoop.toolTimeLimitExempt.contains(tool.name) ? 0 : toolLimit
                            // Any progress from the tool restarts its clock: the limit is for a
                            // tool that has gone quiet, not one that is still working.
                            let activity = ActivityClock()
                            if job.approved {
                                output = try await AgentLoop.bounded(seconds: limit, label: tool.name, activity: activity) {
                                    try await tool.runApprovedLive(arguments: job.arguments, callID: job.callID, existingSubagents: job.existingSubagents) { update in
                                        activity.touch()
                                        sink.yield(.progress(job.callIndex, update))
                                    }
                                }
                            } else {
                                output = try await AgentLoop.bounded(seconds: limit, label: tool.name, activity: activity) {
                                    try await tool.runLive(arguments: job.arguments, callID: job.callID, existingSubagents: job.existingSubagents) { update in
                                        activity.touch()
                                        sink.yield(.progress(job.callIndex, update))
                                    }
                                }
                            }
                            result = .success(output)
                        } catch {
                            // Only a real Stop ends quietly. A tool can throw CancellationError
                            // by itself (a dropped URL request maps to it); re-throwing that left
                            // the loop below waiting forever for a result that never came.
                            if Task.isCancelled { throw CancellationError() }
                            if let timedOut = error as? ToolTimedOut {
                                result = .failure(ToolInputError(timedOut.description))
                            } else if error is CancellationError {
                                result = .failure(ToolInputError("The tool's request was cancelled before it finished."))
                            } else {
                                result = .failure(error)
                            }
                        }
                        sink.yield(.finished(job.callIndex, result))
                    }
                }
                var remaining = jobs.count
                for await event in events {
                    switch event {
                    case .progress(let callIndex, let update):
                        if turn.steps[stepIndex].toolCalls[callIndex].status == .running {
                            let previousSubs = turn.steps[stepIndex].toolCalls[callIndex].subagents
                            turn.steps[stepIndex].toolCalls[callIndex].summary = update.summary
                            if let detail = update.detail {
                                turn.steps[stepIndex].toolCalls[callIndex].detail = detail
                            }
                            var structuralSubagentChange = false
                            if let subagents = update.subagents {
                                structuralSubagentChange = previousSubs?.count != subagents.count || zip(previousSubs ?? [], subagents).contains { old, new in
                                    old.status != new.status || old.toolCallCount != new.toolCallCount || old.model != new.model
                                }
                                turn.steps[stepIndex].toolCalls[callIndex].subagents = subagents
                            }
                            let minInterval = update.subagents != nil ? 0.06 : 0.20
                            if structuralSubagentChange || Date().timeIntervalSince(lastEmit) >= minInterval {
                                emit(milestone: false)
                            }
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

    func outsideContentSeen() -> Bool {
        // Check for inline image or PDF attachments in any user message
        for message in chat.messages {
            if case .user(let user) = message.body {
                for attachment in user.attachments {
                    if attachment.kind == .image || attachment.kind == .pdf {
                        return true
                    }
                }
            }
        }
        
        let earlier = chat.messages.dropLast().compactMap(\.assistantTurn)
        for candidate in earlier + [turn] {
            for step in candidate.steps {
                if !(step.citations ?? []).isEmpty { return true }
                for call in step.toolCalls where call.result != nil && call.status != .waitingForUser {
                    if let tool = tools[call.name] {
                        if tool.bringsOutsideContent { return true }
                    } else if call.name.hasPrefix("mcp_") || Self.outsideContentToolNames.contains(call.name) {
                        return true
                    }
                }
            }
        }
        return false
    }

    // Fallback only — used when the tool isn't in `tools` (e.g. a resumed turn).
    // Prefer `AgentTool.bringsOutsideContent` when the tool object is available.
    static let outsideContentToolNames: Set<String> = [
        "web_search", "read_web_page", "read_file", "search_code", "read_repo_file",
        "read_other_repo_file", "load_repo_rules", "read_attachment", "load_spec",
    ]

    mutating func apply(_ result: (Int, Result<ToolOutput, Error>), stepIndex: Int) {
        let callIndex = result.0
        switch result.1 {
        case .success(let output):
            var record = turn.steps[stepIndex].toolCalls[callIndex]
            record.status = output.isError ? .failed : .done
            record.summary = output.summary
            record.detail = output.detail
            if let subagents = output.subagents {
                record.subagents = subagents
            }
            record.result = Self.capped(output.forModel)
            record.finishedAt = Date()
            if output.billedCost > 0 { record.billedCost = output.billedCost }
            if let preview = output.livePreview { record.livePreview = preview }
            turn.steps[stepIndex].toolCalls[callIndex] = record
            if !output.generatedImages.isEmpty {
                turn.steps[stepIndex].generatedImages = (turn.steps[stepIndex].generatedImages ?? []) + output.generatedImages
            }
            if !output.inlineImages.isEmpty {
                toolInlineImages[record.id] = output.inlineImages
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
            // The second identical failure: tell the AI plainly to find another way now, rather
            // than leaving it to try a third time (owner, 12 November 2026: "aren't you able to do
            // it another way… write your own command to do the same exact thing"). It's noted in
            // the diagnostics too, so a broken MAIPA-G tool gets fixed at the source.
            let record = turn.steps[stepIndex].toolCalls[callIndex]
            let repeats = Self.isTransientFailure(message) ? 0 : turn.steps.flatMap(\.toolCalls).filter {
                $0.id != record.id && $0.name == record.name && $0.arguments == record.arguments && $0.status == .failed
            }.count
            if repeats >= 1 {
                ErrorExplainer.recorder(RepeatedToolFailure(tool: record.name, message: message), area: "AgentLoop", operation: "tool \(record.name) failed twice")
            }
            let nudge = repeats >= 1 ? Self.secondFailureNudge : ""
            fail(stepIndex, callIndex, message: "Error: \(message)" + nudge, summary: "\(base) · didn't work", detail: message)
        }
    }

    static let secondFailureNudge = "\n\n[MAIPA-G] This exact call has now failed twice with the same error, so running it again won't help (a third try is blocked). Work out why from the error, then get the same result another way: a different command or tool, smaller pieces, or your own script on the computer with run_command. If it's one of MAIPA-G's own tools that is broken, do its job by hand. Only ask the person if there's truly no other way, and say what you tried."

    static let thirdFailureMessage = "This exact tool call already failed twice the same way, so MAIPA-G didn't run it a third time. Get the same result another way (a different command or tool, smaller pieces, or your own script on the computer). Ask the person only if there's truly no other way, and say what you tried."

    static func isTransientFailure(_ message: String) -> Bool {
        let lowered = message.lowercased()
        return lowered.contains("rate limit") || lowered.contains("timed out") || lowered.contains("temporarily")
    }

    mutating func fail(_ stepIndex: Int, _ callIndex: Int, message: String, summary: String, detail: String? = nil) {
        turn.steps[stepIndex].toolCalls[callIndex].status = .failed
        turn.steps[stepIndex].toolCalls[callIndex].result = Self.capped(message)
        turn.steps[stepIndex].toolCalls[callIndex].summary = summary
        turn.steps[stepIndex].toolCalls[callIndex].detail = detail ?? message
        turn.steps[stepIndex].toolCalls[callIndex].finishedAt = Date()
    }

    static func capped(_ text: String) -> String {
        Transcript.cappedToolResult(text)
    }

    // MARK: Errors in words

    static func describe(_ error: Error) -> TurnFailure {
        if let api = error as? OpenRouterAPIError {
            let service = api.providerName.isEmpty ? "OpenRouter" : api.providerName
            let isOpenRouter = service == "OpenRouter"
            switch api.kind {
            case .outOfCredits:
                return TurnFailure(kind: .outOfCredits, message: "Your \(service) credit has run out.", detail: api.description)
            case .spendingCapReached:
                return TurnFailure(kind: .outOfCredits, message: "This \(service) key has reached its spending limit.", detail: api.description)
            case .freeDailyLimit:
                return TurnFailure(
                    kind: .freeLimitReached,
                    message: isOpenRouter
                        ? "You've used today's free AI requests. They come back at midnight UTC (8 PM Eastern in summer, 7 PM in winter)."
                        : "You've reached \(service)'s daily request limit.",
                    detail: api.description
                )
            case .rateLimited, .busyRetrySoon:
                return TurnFailure(kind: .providerFailed, message: "The AI on \(service) is busy right now. Try again in a minute.", detail: api.description)
            case .invalidKey:
                return TurnFailure(
                    kind: .signInNeeded,
                    message: isOpenRouter
                        ? "OpenRouter didn't accept the sign-in. Sign in again in Settings."
                        : "\(service) didn't accept the API key. Check it in Settings -> AI Providers.",
                    detail: api.description
                )
            case .contextTooLong:
                return TurnFailure(kind: .tooLong, message: "This chat is too long for this AI. Start a new chat, or pick an AI that can hold more.", detail: api.description)
            case .noModelAvailable:
                return TurnFailure(kind: .providerFailed, message: "No AI on \(service) could take this request just now. Try again, or pick another AI.", detail: api.description)
            case .providerFailed:
                return TurnFailure(kind: .providerFailed, message: "\(service) had a problem partway through. Try again.", detail: api.description)
            case .moderated:
                return TurnFailure(kind: .other, message: "The AI's provider refused this request.", detail: api.description)
            case .appRestricted:
                return TurnFailure(kind: .other, message: "OpenRouter only lets certain listed apps use this AI, so MAIPA-G can't. It's now hidden from the AI picker. Pick another AI, or Auto, and try again.", detail: api.description)
            case .badRequest, .other:
                let explanation = ErrorExplainer.explain(api)
                return TurnFailure(kind: .other, message: explanation.message, detail: api.description)
            }
        }
        if let silent = error as? ModelWentSilent {
            return TurnFailure(
                kind: .providerFailed,
                message: "The AI sent nothing for \(AgentLoop.spokenDuration(silent.seconds)), so I stopped waiting. Try again, or pick another AI.",
                detail: silent.description
            )
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
