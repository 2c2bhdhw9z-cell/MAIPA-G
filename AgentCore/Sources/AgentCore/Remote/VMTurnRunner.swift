import Foundation

/// A GitHub token handed over by the phone. The phone can hand a fresh one over while a long run
/// goes on (`token-refresh.json.gz` in the run's folder); it is read and deleted at once.
public actor HandedOverTokens: GitHubTokenProvider {
    private var token: String
    private let refreshFile: URL?
    private let waitForFresh: TimeInterval
    private var refused = false

    /// `waitForFresh`: after GitHub refuses the token (it lasts about an hour), how long to wait
    /// for the phone to hand over the next one. The phone does that as soon as the app is opened,
    /// so a long reply pauses its GitHub work instead of failing. The app's own GitHub key stays
    /// on the phone; the computer only ever holds these hour-long tokens.
    public init(token: String, refreshFile: URL?, waitForFresh: TimeInterval = 600) {
        self.token = token
        self.refreshFile = refreshFile
        self.waitForFresh = waitForFresh
    }

    public func installationToken() async throws -> String {
        if refused, refreshFile != nil {
            let started = Date()
            while Date().timeIntervalSince(started) < waitForFresh, !takeRefresh() {
                try await Task.sleep(nanoseconds: 5_000_000_000)
            }
            refused = false
        }
        return current()
    }

    public func userToken() async throws -> String { current() }

    public func forgetInstallationToken() async { refused = true }

    /// Takes a handed-over token when one has arrived.
    private func takeRefresh() -> Bool {
        guard let refreshFile, FileManager.default.fileExists(atPath: refreshFile.path) else { return false }
        _ = current()
        return true
    }

    private func current() -> String {
        if let refreshFile, let data = try? Data(contentsOf: refreshFile) {
            try? FileManager.default.removeItem(at: refreshFile)
            if let fresh = try? VMCoding.unpack(VMSecrets.self, from: data), let value = fresh.githubToken, !value.isEmpty {
                token = value
            }
        }
        return token
    }
}

/// Writes the runner's state after each step: `state/<n>.json.gz`, then `seq` names it. Files are
/// renamed into place, so the phone never reads half a file; the last few stay for a phone that is
/// part way through reading one.
public actor VMStateWriter {
    private let folder: URL
    private(set) var seq = 0

    public init(folder: URL) { self.folder = folder }

    @discardableResult
    public func write(_ make: (Int) -> VMTurnState) throws -> Int {
        seq += 1
        let state = make(seq)
        let states = folder.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(at: states, withIntermediateDirectories: true)
        let target = states.appendingPathComponent("\(seq).json.gz")
        try VMCoding.pack(state).write(to: target, options: .atomic)
        try Data("\(seq)\n".utf8).write(to: folder.appendingPathComponent("seq"), options: .atomic)
        if seq > 4 { try? FileManager.default.removeItem(at: states.appendingPathComponent("\(seq - 4).json.gz")) }
        return seq
    }

    private(set) var stagedVersion = 0

    /// Writes the staged files when they changed, so a state stays small while a reply runs.
    @discardableResult
    public func writeStaged(_ files: [CheckpointFile]) throws -> Int {
        stagedVersion += 1
        let directory = folder.appendingPathComponent("staged", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try VMCoding.pack(files).write(to: directory.appendingPathComponent("\(stagedVersion).json.gz"), options: .atomic)
        if stagedVersion > 3 { try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(stagedVersion - 3).json.gz")) }
        return stagedVersion
    }
}

/// Reads a run's files on the computer: the request, and the keys (deleted as soon as read).
public enum VMRunFiles {
    public static func takeSecrets(in folder: URL) throws -> VMSecrets {
        let url = folder.appendingPathComponent("secrets.json.gz")
        defer { try? FileManager.default.removeItem(at: url) }
        let data = try Data(contentsOf: url)
        return try VMCoding.unpack(VMSecrets.self, from: data)
    }

    /// Steer messages not taken yet, oldest first, by file name.
    public static func steers(in folder: URL, after taken: Set<String>) -> [(name: String, text: String)] {
        let directory = folder.appendingPathComponent("steer", isDirectory: true)
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { $0.hasSuffix(".txt") && !taken.contains($0) }.sorted()
        return names.compactMap { name in
            guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)) else { return nil }
            let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : (name, text)
        }
    }

    public static func stopRequested(in folder: URL) -> Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent("stop").path)
    }
}

/// Runs one chat reply on the chat computer. It builds the tools here, with commands running in a
/// real local shell, runs the same AgentLoop the phone runs, and writes its state after every
/// step. The phone reads that state while it's open and catches up when it comes back.
public struct VMTurnRunner: Sendable {
    public let folder: URL
    public let home: URL
    public let machine: String
    private let transport: any HTTPTransport

    public init(folder: URL, home: URL, machine: String = ProcessInfo.processInfo.hostName, transport: any HTTPTransport = URLSessionTransport()) {
        self.folder = folder; self.home = home; self.machine = machine; self.transport = transport
    }

    public func run() async throws {
        let request = try VMCoding.unpack(VMTurnRequest.self, from: Data(contentsOf: folder.appendingPathComponent("request.json.gz")))
        // Keys first, before anything else can start a process.
        let secrets = try VMRunFiles.takeSecrets(in: folder)
        let logger = RedactingLogger(secrets: secrets.allValues)
        let writer = VMStateWriter(folder: folder)
        var turn = request.chat.lastAssistantTurn ?? AssistantTurn()
        turn.status = .running
        let startingTurn = turn
        try await writer.write { VMTurnState(id: request.id, seq: $0, phase: .starting, turn: startingTurn) }
        logger.progress("MAIPA-G started reply \(request.id) on \(machine).")

        // One inbox for the reply and its sub-agents: a message typed while a sub-agent works reaches
        // the AI then, instead of after the sub-agent's half hour ("What is taking so long", 12
        // November 2026, waited 31 minutes).
        let steering = SteeringInbox()
        let setup: Setup
        do {
            setup = try await prepare(request: request, secrets: secrets, logger: logger, steering: steering)
        } catch {
            var failed = turn
            failed.status = .failed
            failed.failure = TurnFailure(kind: .other, message: "The reply couldn't start on your computer: \(logger.redact(ErrorExplainer.explain(error).message))")
            let final = failed
            try await writer.write { VMTurnState(id: request.id, seq: $0, phase: .finished, turn: final, error: final.failure?.message) }
            return
        }

        let input = AgentTurnInput(
            chat: request.chat, route: request.route.route, systemPrompt: request.systemPrompt + Self.promptNote(machine: machine, hasConnectors: setup.connectorCount > 0),
            tools: setup.tools, allowTools: request.allowTools, spendLimit: request.spendLimit,
            attachmentData: request.attachmentData, fallbackModels: request.fallbackModels, requiresInitialSpendApproval: false,
            steering: steering, resumeNote: request.resumeNote, autoApprove: true
        )
        // Tool output too long for the AI is kept whole in ~/.maipa-g/outputs/<callID>.txt, for this
        // reply and its sub-agents, and the AI reads the cut part with read_file.
        let run = ToolOutputArchive.$saver.withValue(DirectoryToolOutputSaver.computer(home: home)) {
            AgentLoop.start(input, environment: setup.environment)
        }
        for text in request.earlySteering { await run.steer(text) }

        // Steer and Stop arrive as files from the phone.
        let pump = Task {
            var taken = Set<String>()
            while !Task.isCancelled {
                for steer in VMRunFiles.steers(in: folder, after: taken) {
                    taken.insert(steer.name)
                    await run.steer(steer.text)
                    await StateBox.shared.setSteersTaken(taken.count)
                }
                if VMRunFiles.stopRequested(in: folder) { run.cancel(); return }
                try? await Task.sleep(nanoseconds: 700_000_000)
            }
        }
        defer { pump.cancel() }

        var lastWrite = Date.distantPast
        // Staged files are written on their own, after a step and only when they changed; each
        // state says which version is current, so a phone that skips states still gets them.
        var staged = await setup.stagedFiles()
        var version = 0
        if let staged { version = (try? await writer.writeStaged(staged)) ?? 0 }
        for await event in run.events {
            guard case .updated(let updated, let milestone) = event else { continue }
            turn = updated
            // Streaming text is written at most a few times a second; steps every time.
            guard milestone || Date().timeIntervalSince(lastWrite) > 0.8 else { continue }
            lastWrite = Date()
            if milestone, let now = await setup.stagedFiles(), now != staged {
                staged = now
                version = (try? await writer.writeStaged(now)) ?? version
            }
            let receipts = await setup.newReceipts()
            let taken = await StateBox.shared.steersTaken
            let memories = await setup.changedMemories()
            let snapshot = turn, current = version
            _ = try? await writer.write { VMTurnState(id: request.id, seq: $0, phase: .running, turn: snapshot, stagedVersion: current, receipts: receipts, steersTaken: taken, memories: memories) }
        }
        pump.cancel()
        if turn.status == .running { turn.status = .stopped }
        let unconsumed = await run.drainUnconsumedSteering()
        staged = await setup.stagedFiles()
        let receipts = await setup.newReceipts()
        let taken = await StateBox.shared.steersTaken
        let memories = await setup.changedMemories()
        let final = turn
        let finalVersion = version
        try await writer.write { VMTurnState(id: request.id, seq: $0, phase: .finished, turn: final, staged: staged, stagedVersion: finalVersion, receipts: receipts, steersTaken: taken, unconsumedSteering: unconsumed, memories: memories) }
        await setup.close()
        logger.progress("MAIPA-G finished reply \(request.id): \(final.status.rawValue).")
    }

    static func promptNote(machine: String, hasConnectors: Bool) -> String {
        """


        ## Where this reply runs
        This reply runs on the person's own Linux computer (`\(machine)`), not on the phone. It keeps going when the app is closed. `run_command` and `computer_task` run right here in a real shell. Sub-agents (`invoke_sub_agent`) and memories work here. The phone's own features (the Workstation, making pictures and videos with picture models\(hasConnectors ? "" : ", connectors")) aren't available in this reply; if the task needs one, say so.
        """
    }

    // MARK: Tools

    struct Setup: Sendable {
        var tools: [any AgentTool]
        var environment: AgentEnvironment
        var changes: ChangeWorkspace?
        var saves: ChangeSession?
        var initialReceiptIDs: Set<UUID>
        var connectorCount: Int
        var sessions: [MCPConnectorSession]
        /// The person's memories, copied here so `add_memory` and `edit_memory` work on the computer.
        var memoryStore: ProductStore<MemoryRecord>? = nil
        var initialMemories: [UUID: MemoryRecord] = [:]

        func stagedFiles() async -> [CheckpointFile]? {
            guard let changes else { return nil }
            return await changes.stagedChanges().map(CheckpointFile.init)
        }

        func newReceipts() async -> [SaveReceipt] {
            guard let saves else { return [] }
            return await saves.receipts().filter { !initialReceiptIDs.contains($0.id) }
        }

        /// Memories added or changed during this reply; the phone saves them.
        func changedMemories() async -> [MemoryRecord]? {
            guard let memoryStore else { return nil }
            let changed = await memoryStore.loadAll().filter { initialMemories[$0.id] != $0 }
            return changed.isEmpty ? nil : changed
        }

        func close() async {}
    }

    func prepare(request: VMTurnRequest, secrets: VMSecrets, logger: RedactingLogger, steering: SteeringInbox? = nil) async throws -> Setup {
        let control = ComputerControl.local(machine: machine, home: home)
        var tools: [any AgentTool] = []
        var changes: ChangeWorkspace?
        var saves: ChangeSession?
        var initialReceiptIDs = Set<UUID>()
        var homePath: String?
        var hookRunner: HookedTool.CommandRunner?
        var hooks: [RepoHook] = []
        if let repo = request.repo {
            guard let token = secrets.githubToken, !token.isEmpty else { throw ToolInputError("GitHub isn't connected for this reply.") }
            let github = GitHubClient(transport: transport, tokens: HandedOverTokens(token: token, refreshFile: folder.appendingPathComponent("token-refresh.json.gz")))
            let store = SnapshotStore(root: home.appendingPathComponent(".maipa-g/snapshots", isDirectory: true))
            let workspace = RepoWorkspace(repo: repo.repo.ref, branch: repo.workingBranch, commit: repo.commit, github: github, store: store)
            let staged = ChangeWorkspace(base: workspace)
            await staged.restoreStaged(repo.staged.map(\.change))
            changes = staged
            let service = GitHubChangeService(github: github)
            let rules = await service.resolveRules(in: workspace, directSaveSetting: repo.directSaveSetting, requestText: request.lastUserMessage)
            let session = ChangeSession(receipts: repo.receipts)
            saves = session
            initialReceiptIDs = Set(repo.receipts.map(\.id))
            let authorization = ChangeAuthorization(request: request.lastUserMessage)
            let savingChoice = SavingStyleChoice()
            tools.append(SetSavingStyleTool(choice: savingChoice, repoName: repo.repo.ref.fullName))
            tools += [
                ListFilesTool(workspace: workspace, changes: staged, computer: control, computerPath: "repos/\(repo.repo.ref.owner)/\(repo.repo.ref.name)"),
                SearchCodeTool(workspace: workspace, changes: staged),
                FileSearchTool(workspace: workspace, changes: staged),
                ReadFileTool(workspace: workspace, changes: staged),
                ReadRepoFileTool(github: github),
                LoadRepoRulesTool(documents: rules.documents),
                CreateFileTool(workspace: staged, authorization: authorization, rules: rules),
                EditFileTool(workspace: staged, authorization: authorization, rules: rules),
                AppendFileTool(workspace: staged, authorization: authorization, rules: rules),
                DeleteFileTool(workspace: staged, authorization: authorization, rules: rules),
                SaveChangesTool(workspace: staged, service: service, session: session, selectedBranch: repo.workingBranch, defaultBranch: repo.repo.defaultBranch, rules: rules, choice: savingChoice),
            ]
            tools.append(LoadSpecTool(
                read: { path in
                    guard case .text(let text, _) = try? await staged.read(path) else { return nil }
                    return text
                },
                list: { ((try? await staged.mergedTree())?.entries ?? []).filter(\.isFile).map(\.path) }
            ))
            // The repo's copy on this computer, for commands. Private repos are cloned here with
            // the token passed to git in its environment only, never on a command line or in a file.
            let path = "repos/\(repo.repo.ref.owner)/\(repo.repo.ref.name)"
            homePath = path
            await prepareCheckout(repo: repo, token: token, path: path, logger: logger)
            let commit = repo.commit
            if await staged.hasStagedChanges() {
                _ = try? await control.syncStagedChanges(homePath: path, cloneURL: nil, commit: commit, changes: await staged.stagedChanges())
            }
            tools.append(SyncStagedToComputerTool(control: control, workspace: staged, homePath: path, cloneURL: nil, commit: commit))
            hookRunner = { command in
                _ = try await control.syncStagedChanges(homePath: path, cloneURL: nil, commit: commit, changes: await staged.stagedChanges())
                return try await control.run("cd \"$HOME/\(path)\" && \(command)")
            }
            hooks = await RepoHooks.load(from: workspace).hooks
            tools.append(AppPreviewTool(control: control, repoHome: path, prepare: {
                if await staged.hasStagedChanges() {
                    _ = try await control.syncStagedChanges(homePath: path, cloneURL: nil, commit: commit, changes: await staged.stagedChanges())
                }
            }))
        }
        tools.append(RunCommandTool(control: control, homePath: homePath))
        tools.append(ComputerTaskTool(control: control, homePath: homePath))
        tools.append(CodeTool(control: control, homePath: homePath))
        tools.append(UpdateSessionInformationTool())
        // Files and pictures made here are kept in the run's folder; the phone copies them into
        // the chat as each state arrives (VMMedia), so they show the same as on the phone.
        let media = AttachmentStore(dataDirectory: folder.appendingPathComponent(VMMedia.folder, isDirectory: true))
        let fileGitHub = secrets.githubToken.flatMap { $0.isEmpty ? nil : GitHubClient(transport: transport, tokens: HandedOverTokens(token: $0, refreshFile: folder.appendingPathComponent("token-refresh.json.gz"))) }
        tools.append(SendFileTool(github: fileGitHub, transport: transport, computer: control, store: media))
        // Memories work here as on the phone: the AI saves what the person wants remembered, and
        // each state carries the new ones back to the phone's Memories.
        let memoryStore = ProductStore<MemoryRecord>(dataDirectory: folder.appendingPathComponent("memories-copy", isDirectory: true), folder: "memories")
        var initialMemories: [UUID: MemoryRecord] = [:]
        for record in request.memories ?? [] {
            if (try? await memoryStore.save(record)) != nil, let saved = await memoryStore.load(record.id) { initialMemories[record.id] = saved }
        }
        tools.append(AddMemoryTool(store: memoryStore))
        tools.append(EditMemoryTool(store: memoryStore))
        tools.append(ShowComputerPictureTool(control: control, store: media))
        if request.webEnabled {
            tools.append(WebSearchTool(transport: transport))
            tools.append(ReadWebPageTool(transport: transport))
        }
        var sessions: [MCPConnectorSession] = []
        for connector in secrets.connectors where connector.configuration.kind == .remote {
            let credential = connector.accessToken.map { ConnectorCredential(accessToken: $0, clientID: "maipa-g-computer") }
            let session = MCPConnectorSession(configuration: connector.configuration, credential: credential, staticHeaders: connector.headers)
            let connected = (try? await AgentLoop.bounded(seconds: 20, label: "Connecting \(connector.configuration.displayName)") { try await session.connect() }) != nil
            guard connected else {
                logger.progress("Connector \(connector.configuration.displayName) couldn't connect from this computer.")
                continue
            }
            sessions.append(session)
            tools += connector.tools.filter { !connector.configuration.disabledTools.contains($0.originalName) }
                .map { MCPTool(definition: $0, session: session) }
        }
        tools = HookedTool.wrap(tools, hooks: hooks, runCommand: hookRunner)
        if request.specMode {
            let gate = request.specGate
            tools = KiroSpecGatedTool.wrap(tools, kind: request.specKind ?? .requirementsFirst, state: { gate })
        }
        if request.supervised, let changes {
            let accepted = Set(request.acceptedChanges)
            tools = SupervisedSaveGate.wrap(tools, unreviewed: {
                SupervisedReview.unreviewed(await changes.stagedChanges(), accepted: accepted).map(\.path)
            })
        }

        let ai = await makeAI(secrets: secrets)
        let catalogue = ai.catalogue, hasOpenRouter = ai.hasOpenRouter
        let thinking = request.route.effort ?? .default
        // Sub-agents work here too, Kiro's way: `invoke_sub_agent`, each in its own context with
        // the tools its role allows (they didn't exist on the computer at all before).
        if request.allowTools {
            let repoContext = request.repo.map {
                SystemPrompt.RepoContext(ref: $0.repo.ref, branch: $0.workingBranch, commit: $0.commit, isPrivate: $0.repo.isPrivate, summary: nil)
            }
            let note = Self.promptNote(machine: machine, hasConnectors: !sessions.isEmpty)
            let reportTools = tools.filter { !AgentDefinition.mutatingTools.contains($0.name) && $0.name != "add_memory" && $0.name != "edit_memory" }
            let subAgents = SubAgentSetup(
                chatModel: request.chat.model, thinking: thinking, primaryModelID: request.route.model, primaryIsFree: request.route.isFree,
                account: AccountState(), catalogue: catalogue, openRouterAvailable: hasOpenRouter, client: ai.client,
                changeTools: tools, reportTools: reportTools,
                prompt: { definition, context in
                    SystemPrompt.make(userLogin: nil, repo: repoContext, agent: definition, workflowContext: context) + note
                }
            )
            let definitions = SubAgentSetup.definitions(excluding: ["introspect", "custom-agent-creator"])
            let coordinator = AgentHelperCoordinator(
                lead: SubAgentSetup.lead, definitions: definitions, context: request.lastUserMessage,
                spendLimit: request.spendLimit, steering: steering, runner: subAgents.runner()
            )
            tools.append(InvokeSubAgentTool(lead: SubAgentSetup.lead, definitions: definitions, coordinator: coordinator, contextTools: tools))
        }
        let environment = AgentEnvironment(
            openRouter: ai.client,
            freeRoute: { ModelRouter.route(choice: .free, difficulty: .normal, thinking: thinking, account: AccountState(), catalogue: catalogue, openRouterAvailable: hasOpenRouter) },
            onOutOfCredits: {}
        )
        return Setup(tools: tools, environment: environment, changes: changes, saves: saves, initialReceiptIDs: initialReceiptIDs,
                     connectorCount: sessions.count, sessions: sessions, memoryStore: memoryStore, initialMemories: initialMemories)
    }

    func prepareCheckout(repo: VMTurnRepo, token: String, path: String, logger: RedactingLogger) async {
        let target = home.appendingPathComponent(path, isDirectory: true)
        let url = repo.repo.ref.webURL.absoluteString + ".git"
        let header = "AUTHORIZATION: basic " + Data("x-access-token:\(token)".utf8).base64EncodedString()
        var environment = ComputerControl.localEnvironment(home: home, from: ProcessInfo.processInfo.environment)
        environment["GIT_TERMINAL_PROMPT"] = "0"
        if !repo.repo.ref.isGitLab {
            environment["GIT_CONFIG_COUNT"] = "1"
            environment["GIT_CONFIG_KEY_0"] = "http.\(repo.repo.ref.webURL.scheme ?? "https")://\(repo.repo.ref.webURL.host ?? "github.com")/.extraheader"
            environment["GIT_CONFIG_VALUE_0"] = header
        }
        do {
            if !FileManager.default.fileExists(atPath: target.appendingPathComponent(".git").path) {
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                let cloned = try await BoundedProcess.run(executable: "/usr/bin/git", arguments: ["clone", "--quiet", url, target.path], directory: home, environment: environment, replacingEnvironment: true, timeout: 900)
                if cloned.exitCode != 0 { logger.progress("Cloning \(repo.repo.ref.fullName) failed: \(logger.redact(cloned.stderr))") }
            }
            let fetched = try await BoundedProcess.run(executable: "/usr/bin/git", arguments: ["fetch", "--quiet", "origin", repo.commit], directory: target, environment: environment, replacingEnvironment: true, timeout: 600)
            if fetched.exitCode != 0 {
                _ = try? await BoundedProcess.run(executable: "/usr/bin/git", arguments: ["fetch", "--quiet", "origin"], directory: target, environment: environment, replacingEnvironment: true, timeout: 600)
            }
            _ = try? await BoundedProcess.run(executable: "/usr/bin/git", arguments: ["checkout", "--quiet", "--detach", repo.commit], directory: target, environment: environment, replacingEnvironment: true, timeout: 120)
        } catch {
            logger.progress("Couldn't prepare the repo's copy: \(logger.redact(ErrorExplainer.explain(error).message))")
        }
    }

    func makeAI(secrets: VMSecrets) async -> (client: OpenRouterClient, catalogue: [String: ModelInfo], hasOpenRouter: Bool) {
        let key = secrets.openRouterKey ?? ""
        let hasOpenRouter = !key.isEmpty && key != "__external_only__"
        var endpoints = secrets.providers.filter(\.isReady)
        var catalogue: [String: ModelInfo] = [:]
        if hasOpenRouter {
            for model in (try? await OpenRouterClient(transport: transport, apiKey: key).models()) ?? [] { catalogue[model.id] = model }
        }
        for index in endpoints.indices {
            if let fetched = try? await AIProviderGateway.fetchModels(for: endpoints[index], transport: transport) {
                endpoints[index].modelWireHints.merge(fetched.wireHints) { _, new in new }
                for model in fetched.models { catalogue[model.id] = model }
            }
        }
        // With the prices, so replies on the computer have a cost ("price unknown" on every one of
        // them before, as the phone's client had the catalogue and this one didn't).
        let client = OpenRouterClient(transport: transport, apiKey: hasOpenRouter ? key : nil, extraProviders: endpoints, catalogueByID: catalogue)
        return (client, catalogue, hasOpenRouter)
    }
}

/// How many steer files the runner has taken, shared between the pump and the state writer.
actor StateBox {
    static let shared = StateBox()
    private(set) var steersTaken = 0
    func setSteersTaken(_ count: Int) { steersTaken = count }
}
