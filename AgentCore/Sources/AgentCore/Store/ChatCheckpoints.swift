import Foundation

// Kiro checkpoints (https://kiro.dev/docs/checkpoints/): one per prompt; restoring one puts the
// files the agent changed back and returns the conversation to that point. Commands and connector
// edits aren't tracked. In MAIPA-G the agent's file changes are the chat's staged changes, plus any
// saves pushed after the checkpoint, which restore can undo with the existing Undo.

/// One staged file as it was at a checkpoint.
public struct CheckpointFile: Codable, Sendable, Hashable {
    public var path: String
    public var data: Data
    public var existed: Bool
    public var isDelete: Bool

    public init(_ change: StagedChange) {
        switch change {
        case .write(let path, let data, let existed):
            self.path = path; self.data = data; self.existed = existed; self.isDelete = false
        case .delete(let path, let previous):
            self.path = path; self.data = previous; self.existed = true; self.isDelete = true
        }
    }

    public var change: StagedChange {
        isDelete ? .delete(path: path, previous: data) : .write(path: path, data: data, existed: existed)
    }
}

/// The chat as it was just before one of the person's messages ran.
public struct ChatCheckpoint: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    /// The person's message this checkpoint comes before.
    public var messageID: UUID
    public var createdAt: Date
    /// Staged files in the chat's main repo at that moment.
    public var files: [CheckpointFile]
    /// False when the staged files were too big to keep; restore then can't put files back.
    public var filesComplete: Bool
    /// How many saves the chat had made by then; later ones are the checkpoint's to undo.
    public var saveCount: Int
    public var kiroSpec: KiroSpecState?
    public var acceptedChanges: [String]?

    public init(id: UUID = UUID(), messageID: UUID, createdAt: Date = Date(), staged: [StagedChange], saveCount: Int, kiroSpec: KiroSpecState?, acceptedChanges: [String]? = nil, byteLimit: Int = ChatCheckpoints.maxBytesPerCheckpoint) {
        self.id = id
        self.messageID = messageID
        self.createdAt = createdAt
        let total = staged.reduce(0) { $0 + CheckpointFile($1).data.count }
        self.filesComplete = total <= byteLimit
        self.files = filesComplete ? staged.map(CheckpointFile.init) : []
        self.saveCount = saveCount
        self.kiroSpec = kiroSpec
        self.acceptedChanges = acceptedChanges
    }

    public var stagedChanges: [StagedChange] { files.map(\.change) }
}

public enum ChatCheckpoints {
    public static let maxCheckpoints = 30
    public static let maxBytesPerCheckpoint = 2 * 1024 * 1024

    /// Adds a checkpoint for a message unless it already has one (a retry keeps the first), keeping the newest few.
    public static func adding(_ checkpoint: ChatCheckpoint, to list: [ChatCheckpoint]) -> [ChatCheckpoint] {
        guard !list.contains(where: { $0.messageID == checkpoint.messageID }) else { return list }
        return Array((list + [checkpoint]).suffix(maxCheckpoints))
    }

    /// Checkpoints whose message is still in the conversation.
    public static func kept(_ list: [ChatCheckpoint], messageIDs: Set<UUID>) -> [ChatCheckpoint] {
        list.filter { messageIDs.contains($0.messageID) }
    }

    /// Saves made after the checkpoint that haven't been undone or closed, newest first.
    public static func savesToUndo(after checkpoint: ChatCheckpoint, receipts: [SaveReceipt]) -> [SaveReceipt] {
        guard checkpoint.saveCount < receipts.count else { return [] }
        return receipts[checkpoint.saveCount...].filter { $0.undoneAt == nil && $0.resolution == nil }.reversed()
    }
}
