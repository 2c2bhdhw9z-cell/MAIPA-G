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
    public static let currentFormat = 1
    public var format = currentFormat
    public var id: UUID
    public var name: String
    public var instructions: String
    public var allowedTools: [String]
    public var createdAt: Date
    public var updatedAt: Date
    public init(id: UUID = UUID(), name: String, instructions: String, allowedTools: [String] = [], createdAt: Date = Date()) {
        self.id = id; self.name = name; self.instructions = instructions; self.allowedTools = allowedTools
        self.createdAt = createdAt; updatedAt = createdAt
    }
}

public struct WorkflowRecord: ProductRecord, Hashable {
    public static let currentFormat = 1
    public var format = currentFormat
    public var id: UUID
    public var name: String
    public var steps: [JSONValue]
    public var createdAt: Date
    public var updatedAt: Date
    public init(id: UUID = UUID(), name: String, steps: [JSONValue] = [], createdAt: Date = Date()) {
        self.id = id; self.name = name; self.steps = steps; self.createdAt = createdAt; updatedAt = createdAt
    }
}

public struct JobRecord: ProductRecord, Hashable {
    public static let currentFormat = 1
    public enum Status: String, Codable, Sendable { case queued, running, needsAnswer, done, stopped, failed }
    public var format = currentFormat
    public var id: UUID
    public var status: Status
    public var title: String
    public var state: JSONValue
    public var createdAt: Date
    public var updatedAt: Date
    public init(id: UUID = UUID(), status: Status = .queued, title: String, state: JSONValue = .object([:]), createdAt: Date = Date()) {
        self.id = id; self.status = status; self.title = title; self.state = state; self.createdAt = createdAt; updatedAt = createdAt
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
