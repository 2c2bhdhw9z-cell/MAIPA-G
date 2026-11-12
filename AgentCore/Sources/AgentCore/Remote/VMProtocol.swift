import Foundation

// Owner's rule, 11 November 2026: all agent work runs on his own Linux computer (the chat computer,
// a Fly.io Sprite), not on the phone and not on GitHub. GitHub only builds the app. The phone hands
// a reply's turn to MAIPAGRunner on that computer, which keeps going when the app is closed, writes
// its state after every step, and is picked up again when the app comes back.
//
// Everything lives under ~/.maipa-g/runs/<id>/ on the computer:
//   request.json   what to run (the chat, the prompt, the route, the repo, the staged files)
//   secrets.json   keys, mode 0600, read and deleted by the runner before any command runs
//   state/<n>.json.gz  the runner's state after step n; `seq` names the newest
//   steer/<n>.txt  messages typed while the reply runs
//   stop           Stop was tapped
//   runner.pid     the runner's process (its own process group)
//   runner.log     progress lines, never a key

/// The layout and names shared by the phone and the runner.
public enum VMRun {
    public static let root = ".maipa-g/runs"
    public static let runnerRoot = ".maipa-g/runner"

    public static func isRunID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 64 && id.allSatisfy { ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "-" }
    }

    /// The run's folder relative to the computer's home folder.
    public static func folder(_ id: String) -> String { "\(root)/\(id)" }

    public static func newTurnID() -> String { "turn-" + UUID().uuidString.lowercased() }
    public static func jobRunID(_ job: UUID) -> String { "job-" + job.uuidString.lowercased() }
}

/// `Route` as it travels to the runner.
public struct VMRoute: Codable, Sendable, Hashable {
    public var model: String
    public var plugins: [JSONValue]
    public var effort: ThinkingLevel?
    public var automaticCaching: Bool
    public var isFree: Bool
    public var isAuto: Bool
    public var label: String
    public var contextWindow: Int
    public var contextBudget: Int
    public var maxOutputTokens: Int?
    public var readsImages: Bool
    public var readsPDFs: Bool
    public var generatesImages: Bool

    public init(_ route: Route) {
        model = route.model; plugins = route.plugins; effort = route.effort
        automaticCaching = route.automaticCaching; isFree = route.isFree; isAuto = route.isAuto
        label = route.label; contextWindow = route.contextWindow; contextBudget = route.contextBudget
        maxOutputTokens = route.maxOutputTokens; readsImages = route.readsImages
        readsPDFs = route.readsPDFs; generatesImages = route.generatesImages
    }

    public var route: Route {
        Route(model: model, plugins: plugins, effort: effort, automaticCaching: automaticCaching,
              isFree: isFree, isAuto: isAuto, label: label, contextWindow: contextWindow,
              contextBudget: contextBudget, maxOutputTokens: maxOutputTokens, readsImages: readsImages,
              readsPDFs: readsPDFs, generatesImages: generatesImages)
    }
}

/// The chat's repo as the runner opens it.
public struct VMTurnRepo: Codable, Sendable, Hashable {
    public var repo: ChatRepo
    /// The branch the reply works on (a still-open pull request's branch, otherwise the chat's).
    public var workingBranch: String
    public var commit: String
    public var directSaveSetting: Bool
    /// The phone's staged files, so the runner starts from exactly what the phone had.
    public var staged: [CheckpointFile]
    /// Saves already made in this chat, so a still-open pull request is continued.
    public var receipts: [SaveReceipt]

    public init(repo: ChatRepo, workingBranch: String, commit: String, directSaveSetting: Bool, staged: [CheckpointFile], receipts: [SaveReceipt]) {
        self.repo = repo; self.workingBranch = workingBranch; self.commit = commit
        self.directSaveSetting = directSaveSetting; self.staged = staged; self.receipts = receipts
    }
}

/// One reply for the runner to carry out.
public struct VMTurnRequest: Codable, Sendable, Hashable {
    public static let currentFormat = 1
    public var format: Int
    public var id: String
    public var chat: Chat
    public var route: VMRoute
    public var systemPrompt: String
    public var allowTools: Bool
    public var spendLimit: Double?
    public var fallbackModels: [String]
    public var resumeNote: String?
    public var lastUserMessage: String
    public var webEnabled: Bool
    public var repo: VMTurnRepo?
    /// Kiro Spec mode: the file tools follow the spec's approval gates.
    public var specMode: Bool
    public var specGate: KiroSpecState?
    public var specKind: KiroSpecKind?
    /// Supervised: nothing is saved until the person reviewed it on the phone.
    public var supervised: Bool
    public var acceptedChanges: [String]
    /// Steering typed before the runner started.
    public var earlySteering: [String]
    /// Pictures and PDFs on the newest message, keyed by attachment id.
    public var attachmentData: [UUID: Data]
    /// The person's saved memories, so the AI on the computer can add and edit them like it does
    /// on the phone. What it saves comes back in `VMTurnState.memories`.
    public var memories: [MemoryRecord]?
    public var createdAt: Date

    public init(
        id: String, chat: Chat, route: Route, systemPrompt: String, allowTools: Bool, spendLimit: Double?,
        fallbackModels: [String], resumeNote: String?, lastUserMessage: String, webEnabled: Bool,
        repo: VMTurnRepo?, specMode: Bool = false, specGate: KiroSpecState? = nil, specKind: KiroSpecKind? = nil,
        supervised: Bool = false, acceptedChanges: [String] = [], earlySteering: [String] = [], attachmentData: [UUID: Data] = [:],
        memories: [MemoryRecord]? = nil, createdAt: Date = Date()
    ) {
        format = Self.currentFormat
        self.id = id; self.chat = chat; self.route = VMRoute(route); self.systemPrompt = systemPrompt
        self.allowTools = allowTools; self.spendLimit = spendLimit; self.fallbackModels = fallbackModels
        self.resumeNote = resumeNote; self.lastUserMessage = lastUserMessage; self.webEnabled = webEnabled
        self.repo = repo; self.specMode = specMode; self.specGate = specGate; self.specKind = specKind; self.supervised = supervised
        self.acceptedChanges = acceptedChanges; self.earlySteering = earlySteering; self.attachmentData = attachmentData
        self.memories = memories; self.createdAt = createdAt
    }
}

/// A remote (HTTP) connector the runner may use: its address, the tools the phone found, and an
/// access token. Never a refresh token: renewing one on the computer would leave the phone with a
/// used-up refresh token.
public struct VMConnector: Codable, Sendable, Hashable {
    public var configuration: ConnectorConfiguration
    public var tools: [ConnectorToolDefinition]
    public var accessToken: String?
    public var headers: [String: String]

    public init(configuration: ConnectorConfiguration, tools: [ConnectorToolDefinition], accessToken: String?, headers: [String: String] = [:]) {
        self.configuration = configuration; self.tools = tools; self.accessToken = accessToken; self.headers = headers
    }
}

/// Keys for one run. Written to a 0600 file and deleted by the runner as soon as it reads them.
public struct VMSecrets: Codable, Sendable, Hashable {
    public var openRouterKey: String?
    public var providers: [AIProviderEndpoint]
    public var githubToken: String?
    /// A second token for the private data repo (jobs only).
    public var dataToken: String?
    public var connectors: [VMConnector]
    /// Values for stdio connectors, as Autonomous jobs had them (`<id>.<name>`).
    public var connectorSecrets: [String: String]

    public init(openRouterKey: String?, providers: [AIProviderEndpoint] = [], githubToken: String?, dataToken: String? = nil, connectors: [VMConnector] = [], connectorSecrets: [String: String] = [:]) {
        self.openRouterKey = openRouterKey; self.providers = providers; self.githubToken = githubToken
        self.dataToken = dataToken; self.connectors = connectors; self.connectorSecrets = connectorSecrets
    }

    /// Every value that must never appear in a log, a state file or the chat.
    public var allValues: [String] {
        var values = [openRouterKey, githubToken, dataToken].compactMap { $0 }
        values += providers.map(\.apiKey)
        values += connectors.compactMap(\.accessToken)
        values += connectors.flatMap { $0.headers.values }
        values += connectorSecrets.values
        return values.filter { $0.count >= 8 }
    }
}

/// What the runner reports after each step.
public struct VMTurnState: Codable, Sendable, Hashable {
    public enum Phase: String, Codable, Sendable { case starting, running, finished }
    public var id: String
    public var seq: Int
    public var phase: Phase
    public var turn: AssistantTurn
    /// The repo's staged files, in the final state. While the reply runs they are written to
    /// `staged/<stagedVersion>.json.gz` only when they change, and the phone reads them from there.
    public var staged: [CheckpointFile]?
    public var stagedVersion: Int
    /// Saves the runner made during this reply.
    public var receipts: [SaveReceipt]
    /// How many steer files the runner has taken so far.
    public var steersTaken: Int
    /// Steering that arrived too late for the AI to see; the phone sends it as the next message.
    public var unconsumedSteering: [String]
    /// Memories the AI added or changed during this reply, for the phone to save.
    public var memories: [MemoryRecord]?
    public var error: String?
    public var updatedAt: Date

    public init(id: String, seq: Int, phase: Phase, turn: AssistantTurn, staged: [CheckpointFile]? = nil, stagedVersion: Int = 0, receipts: [SaveReceipt] = [], steersTaken: Int = 0, unconsumedSteering: [String] = [], memories: [MemoryRecord]? = nil, error: String? = nil, updatedAt: Date = Date()) {
        self.id = id; self.seq = seq; self.phase = phase; self.turn = turn; self.staged = staged; self.stagedVersion = stagedVersion
        self.receipts = receipts; self.steersTaken = steersTaken; self.unconsumedSteering = unconsumedSteering
        self.memories = memories; self.error = error; self.updatedAt = updatedAt
    }

    public var isFinished: Bool { phase == .finished }
}

/// Request and state files are gzip'd JSON, base64'd when they cross the command tool.
public enum VMCoding {
    public static func pack<T: Encodable>(_ value: T) throws -> Data {
        try GzipDeflater.compress(JSONCoding.encoder().encode(value))
    }

    public static func unpack<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONCoding.decoder().decode(type, from: try GzipDeflater.decompress(data))
    }
}

/// An Autonomous job for the runner on the computer (instead of a GitHub Actions run). Its record
/// stays in the private MAIPA-G-data repo, as before, so the phone follows it the same way.
public struct VMJobRequest: Codable, Sendable, Hashable {
    public var jobID: UUID
    public var targetRepository: RepoRef
    public var targetRef: String
    public var dataRepository: RepoRef
    public var dataBranch: String

    public init(jobID: UUID, targetRepository: RepoRef, targetRef: String, dataRepository: RepoRef, dataBranch: String) {
        self.jobID = jobID; self.targetRepository = targetRepository; self.targetRef = targetRef
        self.dataRepository = dataRepository; self.dataBranch = dataBranch
    }
}


/// Files a reply on the computer made (send_file, show_computer_picture) live in the run's folder
/// under `data/`, at the same `media/…` path the chat refers to. The phone copies each one into
/// its own data folder before it shows the step, and before the run's folder is removed.
public enum VMMedia {
    public static let folder = "data"

    /// The made files in a turn that the phone doesn't have yet.
    public static func missing(in turn: AssistantTurn, dataDirectory: URL) -> [AttachmentReference] {
        turn.steps.flatMap { $0.generatedImages ?? [] }.map(\.attachment).filter { reference in
            SnapshotStore.isSafeRelativePath(reference.path) && reference.path.hasPrefix("media/")
                && !FileManager.default.fileExists(atPath: dataDirectory.appendingPathComponent(reference.path).path)
        }
    }

    /// Copies them from the computer.
    public static func fetch(_ references: [AttachmentReference], runID: String, from computer: ComputerControl, into dataDirectory: URL) async {
        for reference in references {
            guard let data = try? await computer.readFile(homePath: "\(VMRun.folder(runID))/\(folder)/\(reference.path)", maxBytes: 260 * 1024 * 1024) else { continue }
            let target = dataDirectory.appendingPathComponent(reference.path)
            try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: target, options: .atomic)
        }
    }
}
