import Foundation

/// Text and already-imported attachment references that have not been sent yet.
public struct ComposerDraft: Codable, Sendable, Hashable {
    public static let folder = "drafts"
    public var format: Int
    public var text: String
    public var attachments: [AttachmentReference]
    public var updatedAt: Date

    public init(text: String = "", attachments: [AttachmentReference] = [], updatedAt: Date = Date()) {
        format = 1
        self.text = text
        self.attachments = attachments
        self.updatedAt = updatedAt
    }

    public var isEmpty: Bool {
        text.isEmpty && attachments.isEmpty
    }

    public static func path(for id: String) -> String {
        "\(folder)/\(id).json"
    }
}
