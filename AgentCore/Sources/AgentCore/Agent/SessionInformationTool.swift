import Foundation

/// What the AI says about the chat as a whole, like Kiro's session status: a short title, what it
/// is doing now, and whether it is waiting on the person or done. The tool only checks and confirms;
/// the app applies it when it sees a finished `update_session_information` call, in a reply that
/// ran on the phone or one followed from the computer:
///
///     if call.name == UpdateSessionInformationTool.toolName, call.status == .done,
///        let update = SessionInformationUpdate.parse(arguments: call.arguments) { … }
public struct SessionInformationUpdate: Sendable, Hashable, Codable {
    public enum Status: String, Sendable, Hashable, Codable, CaseIterable {
        case waitingOnUser = "waiting_on_user"
        case completed
    }

    public static let maxTitleCharacters = 100
    public static let maxDescriptionCharacters = 500

    public var title: String?
    public var description: String?
    public var status: Status?

    public init(title: String? = nil, description: String? = nil, status: Status? = nil) {
        self.title = title
        self.description = description
        self.status = status
    }

    /// The update in a tool call's arguments (JSON text), or nil when they aren't a valid one.
    public static func parse(arguments: String) -> SessionInformationUpdate? {
        guard let value = JSONValue.parse(arguments) else { return nil }
        return try? validated(value)
    }

    /// Checks the arguments the way the tool does: at least one field, a title of at most 100
    /// characters, a description of at most 500, and a known status.
    static func validated(_ arguments: JSONValue) throws -> SessionInformationUpdate {
        guard arguments.objectValue != nil else { throw ToolInputError("Pass an object with title, description and/or status.") }
        let title = arguments.optionalString("title")
        let description = arguments.optionalString("description")
        var status: Status?
        if let raw = arguments.optionalString("status") {
            guard let known = Status(rawValue: raw.lowercased()) else {
                throw ToolInputError("status must be \"waiting_on_user\" or \"completed\" (leave it out while you're working).")
            }
            status = known
        }
        guard title != nil || description != nil || status != nil else {
            throw ToolInputError("Give at least one of title, description or status.")
        }
        if let title, title.count > maxTitleCharacters {
            throw ToolInputError("title is \(title.count) characters; keep it to \(maxTitleCharacters) or fewer (about 6 words).")
        }
        if let description, description.count > maxDescriptionCharacters {
            throw ToolInputError("description is \(description.count) characters; keep it to \(maxDescriptionCharacters) or fewer (one or two sentences).")
        }
        return SessionInformationUpdate(title: title, description: description, status: status)
    }
}

public struct UpdateSessionInformationTool: AgentTool {
    public static let toolName = "update_session_information"
    public let name = UpdateSessionInformationTool.toolName

    public init() {}

    public var spec: ToolSpec {
        ToolSpec(
            name: name,
            description: """
            Update this chat's status so the person can see what you're working on without opening it. Call it once you \
            understand the task (a short title), when the focus of your work changes, when you're blocked on the person \
            (status "waiting_on_user"), and when the whole task is done (status "completed"). Give only the fields that changed. \
            It doesn't interrupt your work and the person doesn't see it as a message, so still answer in the chat. \
            Don't call it after every step: only when something above changes. \
            title: at most 100 characters (about 6 words). description: one or two sentences in the first person, at most 500 \
            characters. Leave status out while you're working.
            """,
            parameters: [
                "type": "object",
                "properties": [
                    "title": ["type": "string", "description": "A short label for the chat, at most 100 characters (about 6 words)."],
                    "description": ["type": "string", "description": "What you're doing now and the progress so far, first person, at most 500 characters."],
                    "status": ["type": "string", "enum": .array(SessionInformationUpdate.Status.allCases.map { .string($0.rawValue) }), "description": "waiting_on_user when blocked on the person; completed when the whole task is done. Leave out otherwise."],
                ],
                "additionalProperties": false,
            ]
        )
    }

    public func runningSummary(for arguments: JSONValue) -> String { "Updating the chat's status…" }

    public func run(arguments: JSONValue, progress: @escaping @Sendable (String) -> Void) async throws -> ToolOutput {
        let update = try SessionInformationUpdate.validated(arguments)
        var parts: [String] = []
        if let title = update.title { parts.append("title “\(title)”") }
        if update.description != nil { parts.append("description") }
        if let status = update.status { parts.append("status \(status.rawValue)") }
        let summary: String
        switch update.status {
        case .completed?: summary = "Marked the chat done"
        case .waitingOnUser?: summary = "Waiting on you"
        case nil: summary = update.title.map { "Status: \($0)" } ?? "Updated the chat's status"
        }
        return ToolOutput(forModel: "Updated the chat's \(parts.joined(separator: ", ")).", summary: summary, detail: update.description)
    }
}
