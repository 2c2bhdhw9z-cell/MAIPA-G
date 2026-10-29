import Foundation

/// Common metadata for JSON records mirrored to MAIPA-G-data.
public protocol ProductRecord: Codable, Sendable, Identifiable where ID == UUID {
    var id: UUID { get }
    var updatedAt: Date { get set }
}

public struct MemoryRecord: ProductRecord, Hashable {
    public static let currentFormat = 1
    public enum Source: String, Codable, Sendable { case star, ai, user }
    public var format: Int
    public var id: UUID
    public var text: String
    public var isEnabled: Bool
    public var source: Source
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), text: String, isEnabled: Bool = true, source: Source = .user, createdAt: Date = Date()) {
        format = Self.currentFormat; self.id = id; self.text = text; self.isEnabled = isEnabled
        self.source = source; self.createdAt = createdAt; updatedAt = createdAt
    }
}

public struct ChatGroupRecord: ProductRecord, Hashable {
    public static let currentFormat = 1
    public var format = currentFormat
    public var id: UUID
    public var name: String
    public var order: Int
    public var createdAt: Date
    public var updatedAt: Date
    public init(id: UUID = UUID(), name: String, order: Int = 0, createdAt: Date = Date()) {
        self.id = id; self.name = name; self.order = order; self.createdAt = createdAt; updatedAt = createdAt
    }
}

public struct CustomAgentRecord: ProductRecord, Hashable {
    public static let currentFormat = 2
    public var format: Int
    public var id: UUID
    public var name: String
    public var summary: String
    public var instructions: String
    public var allowedTools: [String]
    public var difficulty: TaskDifficulty
    public var modelPolicy: AgentModelPolicy
    public var behavior: AgentBehavior
    public var maximumHelpers: Int
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(), name: String, summary: String = "", instructions: String,
        allowedTools: [String] = [], difficulty: TaskDifficulty = .normal,
        modelPolicy: AgentModelPolicy = .automatic, behavior: AgentBehavior = .changesAllowed,
        maximumHelpers: Int = 0, createdAt: Date = Date()
    ) {
        format = Self.currentFormat; self.id = id; self.name = name; self.summary = summary
        self.instructions = instructions; self.allowedTools = allowedTools; self.difficulty = difficulty
        self.modelPolicy = modelPolicy; self.behavior = behavior
        self.maximumHelpers = max(0, min(maximumHelpers, 6))
        self.createdAt = createdAt; updatedAt = createdAt
    }

    public var definition: AgentDefinition {
        AgentDefinition(
            id: "custom:\(id.uuidString.lowercased())", name: name, summary: summary,
            instructions: instructions, allowedTools: allowedTools, difficulty: difficulty,
            modelPolicy: modelPolicy, behavior: behavior, maximumHelpers: maximumHelpers
        )
    }

    enum CodingKeys: String, CodingKey {
        case format, id, name, summary, instructions, allowedTools, difficulty, modelPolicy
        case behavior, maximumHelpers, createdAt, updatedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        format = try c.decodeIfPresent(Int.self, forKey: .format) ?? 1
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        instructions = try c.decodeIfPresent(String.self, forKey: .instructions) ?? ""
        allowedTools = try c.decodeIfPresent([String].self, forKey: .allowedTools) ?? []
        difficulty = try c.decodeIfPresent(TaskDifficulty.self, forKey: .difficulty) ?? .normal
        modelPolicy = try c.decodeIfPresent(AgentModelPolicy.self, forKey: .modelPolicy) ?? .automatic
        behavior = try c.decodeIfPresent(AgentBehavior.self, forKey: .behavior) ?? .changesAllowed
        maximumHelpers = max(0, min(try c.decodeIfPresent(Int.self, forKey: .maximumHelpers) ?? 0, 6))
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
    }
}

public struct WorkflowRecord: ProductRecord, Hashable {
    public static let currentFormat = 2
    public var format: Int
    public var id: UUID
    public var name: String
    public var summary: String
    public var steps: [WorkflowNode]
    public var isApproved: Bool
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), name: String, summary: String = "", steps: [WorkflowNode] = [], isApproved: Bool = false, createdAt: Date = Date()) {
        format = Self.currentFormat; self.id = id; self.name = name; self.summary = summary
        self.steps = steps; self.isApproved = isApproved; self.createdAt = createdAt; updatedAt = createdAt
    }

    public init(definition: WorkflowDefinition, id: UUID = UUID(), createdAt: Date = Date()) {
        self.init(id: id, name: definition.name, summary: definition.summary, steps: definition.steps, isApproved: definition.isApproved, createdAt: createdAt)
    }

    public var definition: WorkflowDefinition {
        WorkflowDefinition(id: "custom:\(id.uuidString.lowercased())", name: name, summary: summary, steps: steps, isApproved: isApproved)
    }

    enum CodingKeys: String, CodingKey { case format, id, name, summary, steps, isApproved, createdAt, updatedAt }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        format = try c.decodeIfPresent(Int.self, forKey: .format) ?? 1
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        steps = (try? c.decode([WorkflowNode].self, forKey: .steps)) ?? []
        isApproved = try c.decodeIfPresent(Bool.self, forKey: .isApproved) ?? false
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
    }
}

public struct JobStepRecord: Codable, Sendable, Hashable, Identifiable {
    public enum Status: String, Codable, Sendable { case pending, running, waiting, done, failed, stopped }
    public var id: UUID
    public var title: String
    public var detail: String?
    public var status: Status
    public var startedAt: Date?
    public var finishedAt: Date?

    public init(id: UUID = UUID(), title: String, detail: String? = nil, status: Status = .pending, startedAt: Date? = nil, finishedAt: Date? = nil) {
        self.id = id; self.title = title; self.detail = detail; self.status = status
        self.startedAt = startedAt; self.finishedAt = finishedAt
    }
}

public struct JobQuestion: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var text: String
    public var options: [String]
    public var answer: String?
    public var isApproval: Bool

    public init(id: UUID = UUID(), text: String, options: [String] = [], answer: String? = nil, isApproval: Bool = false) {
        self.id = id; self.text = text; self.options = options; self.answer = answer; self.isApproval = isApproval
    }
}

public struct JobResult: Codable, Sendable, Hashable {
    public var summary: String
    public var pullRequest: GitHubPullRequest?
    public var commit: String?
    public var buildURL: String?
    public var artifactURL: String?

    public init(summary: String, pullRequest: GitHubPullRequest? = nil, commit: String? = nil, buildURL: String? = nil, artifactURL: String? = nil) {
        self.summary = summary; self.pullRequest = pullRequest; self.commit = commit
        self.buildURL = buildURL; self.artifactURL = artifactURL
    }
}

/// A private, restartable Autonomous job. The whole record is checkpointed after each agent or
/// tool step, so a fresh Actions run can continue the same assistant turn without repeating work.
public struct JobRecord: ProductRecord, Hashable {
    public static let currentFormat = 2
    public enum Status: String, Codable, Sendable {
        case queued, settingUp, running, needsApproval, needsAnswer, handingOver, done, stopped, failed
    }
    public var format: Int
    public var id: UUID
    public var status: Status
    public var title: String
    /// Private runner state. This can contain the request and transcript and must never be logged.
    public var state: JSONValue
    public var targetRepo: RepoRef?
    public var targetRef: String?
    public var defaultBranch: String?
    public var directSave: Bool
    public var steps: [JobStepRecord]
    public var questions: [JobQuestion]
    public var cumulativeCost: Double
    public var handoverGeneration: Int
    public var workflowRunID: Int?
    public var workflowRunURL: String?
    public var logsURL: String?
    public var result: JobResult?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(), status: Status = .queued, title: String,
        state: JSONValue = .object([:]), targetRepo: RepoRef? = nil, targetRef: String? = nil,
        defaultBranch: String? = nil, directSave: Bool = false,
        steps: [JobStepRecord] = [], questions: [JobQuestion] = [], cumulativeCost: Double = 0,
        handoverGeneration: Int = 0, workflowRunID: Int? = nil, workflowRunURL: String? = nil,
        logsURL: String? = nil, result: JobResult? = nil, createdAt: Date = Date()
    ) {
        format = Self.currentFormat; self.id = id; self.status = status; self.title = title
        self.state = state; self.targetRepo = targetRepo; self.targetRef = targetRef
        self.defaultBranch = defaultBranch; self.directSave = directSave; self.steps = steps
        self.questions = questions; self.cumulativeCost = cumulativeCost
        self.handoverGeneration = handoverGeneration; self.workflowRunID = workflowRunID
        self.workflowRunURL = workflowRunURL; self.logsURL = logsURL; self.result = result
        self.createdAt = createdAt; updatedAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case format, id, status, title, state, targetRepo, targetRef, defaultBranch, directSave
        case steps, questions, cumulativeCost, handoverGeneration, workflowRunID, workflowRunURL
        case logsURL, result, createdAt, updatedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        format = try c.decodeIfPresent(Int.self, forKey: .format) ?? 1
        id = try c.decode(UUID.self, forKey: .id)
        status = try c.decodeIfPresent(Status.self, forKey: .status) ?? .queued
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "Autonomous job"
        state = try c.decodeIfPresent(JSONValue.self, forKey: .state) ?? .object([:])
        targetRepo = try c.decodeIfPresent(RepoRef.self, forKey: .targetRepo)
        targetRef = try c.decodeIfPresent(String.self, forKey: .targetRef)
        defaultBranch = try c.decodeIfPresent(String.self, forKey: .defaultBranch)
        directSave = try c.decodeIfPresent(Bool.self, forKey: .directSave) ?? false
        steps = try c.decodeIfPresent([JobStepRecord].self, forKey: .steps) ?? []
        questions = try c.decodeIfPresent([JobQuestion].self, forKey: .questions) ?? []
        cumulativeCost = try c.decodeIfPresent(Double.self, forKey: .cumulativeCost) ?? 0
        handoverGeneration = try c.decodeIfPresent(Int.self, forKey: .handoverGeneration) ?? 0
        workflowRunID = try c.decodeIfPresent(Int.self, forKey: .workflowRunID)
        workflowRunURL = try c.decodeIfPresent(String.self, forKey: .workflowRunURL)
        logsURL = try c.decodeIfPresent(String.self, forKey: .logsURL)
        result = try c.decodeIfPresent(JobResult.self, forKey: .result)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
    }
}

public struct ConnectorRecord: ProductRecord, Hashable {
    public static let currentFormat = 1
    public var format = currentFormat
    public var id: UUID
    public var serverID: String
    public var displayName: String
    public var isEnabled: Bool
    public var configuration: JSONValue
    public var createdAt: Date
    public var updatedAt: Date
    public init(id: UUID = UUID(), serverID: String, displayName: String, isEnabled: Bool = true, configuration: JSONValue = .object([:]), createdAt: Date = Date()) {
        self.id = id; self.serverID = serverID; self.displayName = displayName; self.isEnabled = isEnabled
        self.configuration = configuration; self.createdAt = createdAt; updatedAt = createdAt
    }
}

public struct SpecRecord: ProductRecord, Hashable {
    public static let currentFormat = 1
    public var format = currentFormat
    public var id: UUID
    public var repo: RepoRef
    public var slug: String
    public var state: JSONValue
    public var createdAt: Date
    public var updatedAt: Date
    public init(id: UUID = UUID(), repo: RepoRef, slug: String, state: JSONValue = .object([:]), createdAt: Date = Date()) {
        self.id = id; self.repo = repo; self.slug = slug; self.state = state; self.createdAt = createdAt; updatedAt = createdAt
    }
}

/// Enough immutable Git state to reverse only MAIPA-G's latest save.
public struct SaveReceipt: Codable, Sendable, Hashable, Identifiable {
    public struct FileState: Codable, Sendable, Hashable {
        public var path: String
        public var beforeBlob: String?
        public var afterBlob: String?
        public init(path: String, beforeBlob: String?, afterBlob: String?) {
            self.path = path; self.beforeBlob = beforeBlob; self.afterBlob = afterBlob
        }
    }
    public var id: UUID
    public var repo: RepoRef
    public var branch: String
    public var baseCommit: String
    public var savedCommit: String
    public var files: [FileState]
    public var pullRequest: GitHubPullRequest?
    public var createdAt: Date
    public var undoneAt: Date?
    public var resolution: String?
    public init(id: UUID = UUID(), repo: RepoRef, branch: String, baseCommit: String, savedCommit: String, files: [FileState], pullRequest: GitHubPullRequest? = nil, createdAt: Date = Date()) {
        self.id = id; self.repo = repo; self.branch = branch; self.baseCommit = baseCommit; self.savedCommit = savedCommit
        self.files = files; self.pullRequest = pullRequest; self.createdAt = createdAt; self.resolution = nil
    }
}
