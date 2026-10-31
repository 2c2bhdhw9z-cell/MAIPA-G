import AgentCore
import Contacts
import EventKit
import Foundation
import UIKit

enum AppleDeviceIntegrations {
    static func requestAuthorization(for appleKey: String) async throws -> Bool {
        switch appleKey {
        case "calendar":
            return try await EKEventStore().requestFullAccessToEvents()
        case "reminders":
            return try await EKEventStore().requestFullAccessToReminders()
        case "contacts":
            return try await CNContactStore().requestAccess(for: .contacts)
        default:
            return true
        }
    }

    static func definitions(for configuration: ConnectorConfiguration) -> [ConnectorToolDefinition] {
        makeTools(configuration: configuration).map(\.definition)
    }

    static func tools(for configuration: ConnectorConfiguration) -> [any AgentTool] {
        let disabled = configuration.disabledTools
        return makeTools(configuration: configuration).filter { !disabled.contains($0.definition.originalName) }
    }

    private static func makeTools(configuration: ConnectorConfiguration) -> [any AppleDescribedTool] {
        let key = configuration.launchValues["apple_key"] ?? configuration.serverID.replacingOccurrences(of: "apple:", with: "")
        switch key {
        case "calendar", "apple_calendar":
            return [AppleCalendarListTool(configuration: configuration), AppleCalendarCreateTool(configuration: configuration), AppleCalendarDeleteTool(configuration: configuration)]
        case "reminders", "apple_reminders":
            return [AppleRemindersListTool(configuration: configuration), AppleRemindersCreateTool(configuration: configuration), AppleRemindersCompleteTool(configuration: configuration)]
        case "contacts", "apple_contacts":
            return [AppleContactsSearchTool(configuration: configuration)]
        case "icloud_drive":
            return [ICloudDriveListTool(configuration: configuration), ICloudDriveReadTool(configuration: configuration), ICloudDriveWriteTool(configuration: configuration)]
        case "mail", "apple_mail":
            return [AppleMailComposeTool(configuration: configuration)]
        case "imessage":
            return [AppleMessagesComposeTool(configuration: configuration)]
        case "notes", "apple_notes":
            return [AppleNotesShareTool(configuration: configuration)]
        case "obsidian":
            return [ObsidianNoteTool(configuration: configuration)]
        case "evernote":
            return [EvernoteShareTool(configuration: configuration)]
        default:
            return []
        }
    }
}

private protocol AppleDescribedTool: AgentTool {
    var definition: ConnectorToolDefinition { get }
}

// MARK: - Apple Calendar

private struct AppleCalendarListTool: AppleDescribedTool {
    let configuration: ConnectorConfiguration
    var definition: ConnectorToolDefinition {
        ConnectorToolDefinition(
            serverID: configuration.serverID, serverName: configuration.displayName, originalName: "list_events",
            title: "List Calendar events",
            description: "List events from Apple Calendar on this iPhone between `days_back` (default 0) and `days_ahead` (default 14), optionally filtered by `query`.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "days_ahead": ["type": "integer", "description": "Days ahead from today to search (1-365, default 14)."],
                    "days_back": ["type": "integer", "description": "Days before today to include (0-365, default 0)."],
                    "query": ["type": "string", "description": "Optional title/location text filter."]
                ]
            ],
            readOnlyHint: true
        )
    }
    var name: String { definition.namespacedName }
    var spec: ToolSpec { ToolSpec(name: name, description: definition.description, parameters: definition.inputSchema) }
    var bringsOutsideContent: Bool { true }
    func runningSummary(for arguments: JSONValue) -> String { "Reading Apple Calendar…" }

    func run(arguments: JSONValue, progress: @escaping @Sendable (String) -> Void) async throws -> ToolOutput {
        guard try await EKEventStore().requestFullAccessToEvents() else {
            throw ToolInputError("Calendar permission is off. Enable Calendar access for MAIPA-G in iOS Settings.")
        }
        let ahead = min(max(arguments.optionalInt("days_ahead") ?? 14, 1), 365)
        let back = min(max(arguments.optionalInt("days_back") ?? 0, 0), 365)
        let filter = (arguments["query"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        let store = EKEventStore()
        let now = Date()
        let start = Calendar.current.date(byAdding: .day, value: -back, to: now) ?? now
        let end = Calendar.current.date(byAdding: .day, value: ahead, to: now) ?? now.addingTimeInterval(86_400 * 14)
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let formatter = ISO8601DateFormatter()
        let events = store.events(matching: predicate)
            .filter { filter.isEmpty || ($0.title ?? "").lowercased().contains(filter) || ($0.location ?? "").lowercased().contains(filter) }
            .prefix(50)
            .map { ev -> String in
                let id = ev.eventIdentifier ?? ""
                let title = ev.title ?? "(Untitled)"
                let loc = (ev.location?.isEmpty == false) ? " @ \(ev.location!)" : ""
                let cal = ev.calendar?.title ?? "Calendar"
                return "- [\(id)] \(title)\(loc) | \(formatter.string(from: ev.startDate)) → \(formatter.string(from: ev.endDate)) (\(cal))"
            }
        let body = events.isEmpty ? "No matching calendar events found in that date range." : events.joined(separator: "\n")
        return ToolOutput(forModel: body, summary: "Read \(events.count) calendar events", detail: body)
    }
}

private struct AppleCalendarCreateTool: AppleDescribedTool {
    let configuration: ConnectorConfiguration
    var definition: ConnectorToolDefinition {
        ConnectorToolDefinition(
            serverID: configuration.serverID, serverName: configuration.displayName, originalName: "create_event",
            title: "Create Calendar event",
            description: "Create an event in Apple Calendar on this iPhone using ISO-8601 `start_iso` and `end_iso` timestamps.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "title": ["type": "string", "description": "Event title."],
                    "start_iso": ["type": "string", "description": "Start time in ISO-8601 format (e.g. 2026-10-31T14:00:00-04:00)."],
                    "end_iso": ["type": "string", "description": "End time in ISO-8601 format."],
                    "location": ["type": "string", "description": "Optional location."],
                    "notes": ["type": "string", "description": "Optional event notes."]
                ],
                "required": ["title", "start_iso", "end_iso"]
            ]
        )
    }
    var name: String { definition.namespacedName }
    var spec: ToolSpec { ToolSpec(name: name, description: definition.description, parameters: definition.inputSchema) }
    func runningSummary(for arguments: JSONValue) -> String { "Adding Calendar event…" }
    func approvalAfterOutsideContent(for arguments: JSONValue) async -> ToolApprovalRequest? {
        ToolApprovalRequest(question: "Add \"\(arguments["title"]?.stringValue ?? "event")\" to your Apple Calendar?", allowLabel: "Add event")
    }
    func run(arguments: JSONValue, progress: @escaping @Sendable (String) -> Void) async throws -> ToolOutput {
        guard try await EKEventStore().requestFullAccessToEvents() else {
            throw ToolInputError("Calendar permission is off in iOS Settings.")
        }
        let title = try arguments.requiredString("title")
        let startStr = try arguments.requiredString("start_iso")
        let endStr = try arguments.requiredString("end_iso")
        guard let startDate = FlexibleISODateParser.parse(startStr),
              let endDate = FlexibleISODateParser.parse(endStr) else {
            throw ToolInputError("Use ISO-8601 dates such as 2026-10-31T14:00:00-04:00 or 2026-10-31T14:00:00.")
        }
        let store = EKEventStore()
        let event = EKEvent(eventStore: store)
        event.title = title
        event.startDate = startDate
        event.endDate = endDate
        event.location = arguments["location"]?.stringValue
        event.notes = arguments["notes"]?.stringValue
        event.calendar = store.defaultCalendarForNewEvents
        try store.save(event, span: .thisEvent)
        let id = event.eventIdentifier ?? "saved"
        return ToolOutput(forModel: "Created Apple Calendar event '\(title)' (id: \(id)).", summary: "Added '\(title)' to Calendar")
    }
}

private struct AppleCalendarDeleteTool: AppleDescribedTool {
    let configuration: ConnectorConfiguration
    var definition: ConnectorToolDefinition {
        ConnectorToolDefinition(
            serverID: configuration.serverID, serverName: configuration.displayName, originalName: "delete_event",
            title: "Delete Calendar event",
            description: "Delete an event from Apple Calendar by its event ID.",
            inputSchema: ["type": "object", "properties": ["event_id": ["type": "string", "description": "Event identifier from list_events."]], "required": ["event_id"]],
            destructiveHint: true
        )
    }
    var name: String { definition.namespacedName }
    var spec: ToolSpec { ToolSpec(name: name, description: definition.description, parameters: definition.inputSchema) }
    func runningSummary(for arguments: JSONValue) -> String { "Removing Calendar event…" }
    func approvalRequest(for arguments: JSONValue) async -> ToolApprovalRequest? {
        ToolApprovalRequest(question: "Delete this event from your Apple Calendar?", allowLabel: "Delete event")
    }
    func run(arguments: JSONValue, progress: @escaping @Sendable (String) -> Void) async throws -> ToolOutput {
        guard try await EKEventStore().requestFullAccessToEvents() else {
            throw ToolInputError("Calendar permission is off in iOS Settings.")
        }
        let id = try arguments.requiredString("event_id")
        let store = EKEventStore()
        guard let ev = store.event(withIdentifier: id) else { throw ToolInputError("No calendar event found with id \(id).") }
        let title = ev.title ?? "event"
        try store.remove(ev, span: .thisEvent)
        return ToolOutput(forModel: "Deleted event '\(title)'.", summary: "Deleted '\(title)'")
    }
}

// MARK: - Apple Reminders

private struct AppleRemindersListTool: AppleDescribedTool {
    let configuration: ConnectorConfiguration
    var definition: ConnectorToolDefinition {
        ConnectorToolDefinition(
            serverID: configuration.serverID, serverName: configuration.displayName, originalName: "list_reminders",
            title: "List Reminders",
            description: "List incomplete (or all) items from Apple Reminders on this iPhone.",
            inputSchema: ["type": "object", "properties": ["include_completed": ["type": "boolean", "description": "Include completed reminders (default false)."]]],
            readOnlyHint: true
        )
    }
    var name: String { definition.namespacedName }
    var spec: ToolSpec { ToolSpec(name: name, description: definition.description, parameters: definition.inputSchema) }
    var bringsOutsideContent: Bool { true }
    func runningSummary(for arguments: JSONValue) -> String { "Reading Apple Reminders…" }

    func run(arguments: JSONValue, progress: @escaping @Sendable (String) -> Void) async throws -> ToolOutput {
        guard try await EKEventStore().requestFullAccessToReminders() else {
            throw ToolInputError("Reminders permission is off in iOS Settings.")
        }
        let includeCompleted = arguments["include_completed"]?.boolValue ?? false
        let lines = await Self.fetchReminderLines(includeCompleted: includeCompleted)
        let out = lines.isEmpty ? "No reminders found." : lines.joined(separator: "\n")
        return ToolOutput(forModel: out, summary: "Read \(lines.count) reminders", detail: out)
    }

    private static func fetchReminderLines(includeCompleted: Bool) async -> [String] {
        await withCheckedContinuation { continuation in
            let store = EKEventStore()
            let predicate = includeCompleted
                ? store.predicateForReminders(in: nil)
                : store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
            store.fetchReminders(matching: predicate) { items in
                let mapped = (items ?? []).prefix(80).map { item -> String in
                    let mark = item.isCompleted ? "[x]" : "[ ]"
                    let list = item.calendar?.title ?? "Reminders"
                    return "\(mark) [\(item.calendarItemIdentifier)] \(item.title ?? "(Untitled)") (\(list))"
                }
                continuation.resume(returning: mapped)
            }
        }
    }
}

private struct AppleRemindersCreateTool: AppleDescribedTool {
    let configuration: ConnectorConfiguration
    var definition: ConnectorToolDefinition {
        ConnectorToolDefinition(
            serverID: configuration.serverID, serverName: configuration.displayName, originalName: "create_reminder",
            title: "Create Reminder",
            description: "Add a new reminder to Apple Reminders on this iPhone.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "title": ["type": "string", "description": "Reminder title."],
                    "notes": ["type": "string", "description": "Optional notes."],
                    "due_iso": ["type": "string", "description": "Optional ISO-8601 due date/time."]
                ],
                "required": ["title"]
            ]
        )
    }
    var name: String { definition.namespacedName }
    var spec: ToolSpec { ToolSpec(name: name, description: definition.description, parameters: definition.inputSchema) }
    func runningSummary(for arguments: JSONValue) -> String { "Adding Apple Reminder…" }
    func approvalAfterOutsideContent(for arguments: JSONValue) async -> ToolApprovalRequest? {
        ToolApprovalRequest(question: "Add reminder \"\(arguments["title"]?.stringValue ?? "")\" to Apple Reminders?", allowLabel: "Add reminder")
    }
    func run(arguments: JSONValue, progress: @escaping @Sendable (String) -> Void) async throws -> ToolOutput {
        guard try await EKEventStore().requestFullAccessToReminders() else {
            throw ToolInputError("Reminders permission is off in iOS Settings.")
        }
        let title = try arguments.requiredString("title")
        let store = EKEventStore()
        let rem = EKReminder(eventStore: store)
        rem.title = title
        rem.notes = arguments["notes"]?.stringValue
        rem.calendar = store.defaultCalendarForNewReminders()
        if let dueStr = arguments["due_iso"]?.stringValue, let dueDate = FlexibleISODateParser.parse(dueStr) {
            rem.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: dueDate)
        }
        try store.save(rem, commit: true)
        return ToolOutput(forModel: "Created reminder '\(title)' (id: \(rem.calendarItemIdentifier)).", summary: "Added reminder '\(title)'")
    }
}

private struct AppleRemindersCompleteTool: AppleDescribedTool {
    let configuration: ConnectorConfiguration
    var definition: ConnectorToolDefinition {
        ConnectorToolDefinition(
            serverID: configuration.serverID, serverName: configuration.displayName, originalName: "complete_reminder",
            title: "Complete Reminder",
            description: "Mark an Apple Reminder completed by its ID.",
            inputSchema: ["type": "object", "properties": ["reminder_id": ["type": "string", "description": "Identifier from list_reminders."]], "required": ["reminder_id"]]
        )
    }
    var name: String { definition.namespacedName }
    var spec: ToolSpec { ToolSpec(name: name, description: definition.description, parameters: definition.inputSchema) }
    func runningSummary(for arguments: JSONValue) -> String { "Completing Reminder…" }
    func approvalAfterOutsideContent(for arguments: JSONValue) async -> ToolApprovalRequest? {
        ToolApprovalRequest(question: "Mark this Apple Reminder complete?", allowLabel: "Complete")
    }
    func run(arguments: JSONValue, progress: @escaping @Sendable (String) -> Void) async throws -> ToolOutput {
        guard try await EKEventStore().requestFullAccessToReminders() else {
            throw ToolInputError("Reminders permission is off in iOS Settings.")
        }
        let id = try arguments.requiredString("reminder_id")
        let store = EKEventStore()
        guard let item = store.calendarItem(withIdentifier: id) as? EKReminder else {
            throw ToolInputError("No reminder found with id \(id).")
        }
        item.isCompleted = true
        try store.save(item, commit: true)
        return ToolOutput(forModel: "Marked '\(item.title ?? "reminder")' complete.", summary: "Completed reminder")
    }
}

// MARK: - Apple Contacts

private struct AppleContactsSearchTool: AppleDescribedTool {
    let configuration: ConnectorConfiguration
    var definition: ConnectorToolDefinition {
        ConnectorToolDefinition(
            serverID: configuration.serverID, serverName: configuration.displayName, originalName: "search_contacts",
            title: "Search Contacts",
            description: "Search names, email addresses and phone numbers in Apple Contacts on this iPhone.",
            inputSchema: ["type": "object", "properties": ["query": ["type": "string", "description": "Name, email or company to search."]], "required": ["query"]],
            readOnlyHint: true
        )
    }
    var name: String { definition.namespacedName }
    var spec: ToolSpec { ToolSpec(name: name, description: definition.description, parameters: definition.inputSchema) }
    var bringsOutsideContent: Bool { true }
    func runningSummary(for arguments: JSONValue) -> String { "Searching Apple Contacts…" }
    func run(arguments: JSONValue, progress: @escaping @Sendable (String) -> Void) async throws -> ToolOutput {
        guard try await CNContactStore().requestAccess(for: .contacts) else {
            throw ToolInputError("Contacts permission is off in iOS Settings.")
        }
        let query = try arguments.requiredString("query").trimmingCharacters(in: .whitespacesAndNewlines)
        let lines: [String] = try await Task.detached {
            let store = CNContactStore()
            let keys: [CNKeyDescriptor] = [
                CNContactGivenNameKey as CNKeyDescriptor,
                CNContactFamilyNameKey as CNKeyDescriptor,
                CNContactOrganizationNameKey as CNKeyDescriptor,
                CNContactEmailAddressesKey as CNKeyDescriptor,
                CNContactPhoneNumbersKey as CNKeyDescriptor,
            ]
            let predicate = CNContact.predicateForContacts(matchingName: query)
            let matches = try store.unifiedContacts(matching: predicate, keysToFetch: keys)
            return matches.prefix(30).map { c in
                let fullName = [c.givenName, c.familyName].filter { !$0.isEmpty }.joined(separator: " ")
                let emails = c.emailAddresses.map { String($0.value) }.joined(separator: ", ")
                let phones = c.phoneNumbers.map { $0.value.stringValue }.joined(separator: ", ")
                let org = c.organizationName.isEmpty ? "" : " (\(c.organizationName))"
                return "- \(fullName.isEmpty ? "(No name)" : fullName)\(org) | Phones: \(phones.isEmpty ? "none" : phones) | Emails: \(emails.isEmpty ? "none" : emails)"
            }
        }.value
        let out = lines.isEmpty ? "No contacts matched '\(query)'." : lines.joined(separator: "\n")
        return ToolOutput(forModel: out, summary: "Found \(lines.count) contacts", detail: out)
    }
}

// MARK: - iCloud Drive / Files Folder

private enum ICloudWorkspace {
    static var root: URL {
        if let container = FileManager.default.url(forUbiquityContainerIdentifier: nil)?.appendingPathComponent("Documents", isDirectory: true) {
            try? FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
            return container
        }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("iCloud-Drive", isDirectory: true)
        try? FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        return docs
    }

    static func resolve(_ relativePath: String) throws -> URL {
        let clean = relativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard !clean.contains("..") else { throw ToolInputError("Relative paths inside iCloud Drive cannot contain '..'.") }
        let base = root.standardizedFileURL
        let target = (clean.isEmpty ? base : base.appendingPathComponent(clean)).standardizedFileURL
        guard target.path == base.path || target.path.hasPrefix(base.path + "/") else {
            throw ToolInputError("Path outside iCloud Drive workspace.")
        }
        return target
    }
}

private struct ICloudDriveListTool: AppleDescribedTool {
    let configuration: ConnectorConfiguration
    var definition: ConnectorToolDefinition {
        ConnectorToolDefinition(
            serverID: configuration.serverID, serverName: configuration.displayName, originalName: "list_files",
            title: "List iCloud Drive files", description: "List files in MAIPA-G's iCloud Drive / Files folder.",
            inputSchema: ["type": "object", "properties": ["folder": ["type": "string", "description": "Optional subfolder path."]]],
            readOnlyHint: true
        )
    }
    var name: String { definition.namespacedName }
    var spec: ToolSpec { ToolSpec(name: name, description: definition.description, parameters: definition.inputSchema) }
    var bringsOutsideContent: Bool { true }
    func runningSummary(for arguments: JSONValue) -> String { "Listing iCloud Drive files…" }
    func run(arguments: JSONValue, progress: @escaping @Sendable (String) -> Void) async throws -> ToolOutput {
        let dir = try ICloudWorkspace.resolve(arguments["folder"]?.stringValue ?? "")
        let items = (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.sorted() ?? []
        let out = items.isEmpty ? "Folder is empty (\(dir.lastPathComponent))." : items.joined(separator: "\n")
        return ToolOutput(forModel: out, summary: "Listed \(items.count) files", detail: out)
    }
}

private struct ICloudDriveReadTool: AppleDescribedTool {
    let configuration: ConnectorConfiguration
    var definition: ConnectorToolDefinition {
        ConnectorToolDefinition(
            serverID: configuration.serverID, serverName: configuration.displayName, originalName: "read_file",
            title: "Read iCloud Drive file", description: "Read a UTF-8 text/Markdown/JSON/CSV file from MAIPA-G's iCloud Drive folder.",
            inputSchema: ["type": "object", "properties": ["path": ["type": "string", "description": "Relative file path."]], "required": ["path"]],
            readOnlyHint: true
        )
    }
    var name: String { definition.namespacedName }
    var spec: ToolSpec { ToolSpec(name: name, description: definition.description, parameters: definition.inputSchema) }
    var bringsOutsideContent: Bool { true }
    func runningSummary(for arguments: JSONValue) -> String { "Reading iCloud Drive file…" }
    func run(arguments: JSONValue, progress: @escaping @Sendable (String) -> Void) async throws -> ToolOutput {
        let path = try arguments.requiredString("path")
        let url = try ICloudWorkspace.resolve(path)
        let data = try Data(contentsOf: url)
        let text = String(decoding: data.prefix(40_000), as: UTF8.self)
        return ToolOutput(forModel: text, summary: "Read \(path)", detail: String(text.prefix(1_200)))
    }
}

private struct ICloudDriveWriteTool: AppleDescribedTool {
    let configuration: ConnectorConfiguration
    var definition: ConnectorToolDefinition {
        ConnectorToolDefinition(
            serverID: configuration.serverID, serverName: configuration.displayName, originalName: "write_file",
            title: "Save file to iCloud Drive", description: "Write a text or Markdown file into MAIPA-G's iCloud Drive / Files folder.",
            inputSchema: ["type": "object", "properties": ["path": ["type": "string", "description": "Relative file path (e.g. notes/summary.md)."], "content": ["type": "string", "description": "File content."]], "required": ["path", "content"]]
        )
    }
    var name: String { definition.namespacedName }
    var spec: ToolSpec { ToolSpec(name: name, description: definition.description, parameters: definition.inputSchema) }
    func runningSummary(for arguments: JSONValue) -> String { "Saving file to iCloud Drive…" }
    func approvalAfterOutsideContent(for arguments: JSONValue) async -> ToolApprovalRequest? {
        ToolApprovalRequest(question: "Save file \"\(arguments["path"]?.stringValue ?? "")\" to iCloud Drive?", allowLabel: "Save file")
    }
    func run(arguments: JSONValue, progress: @escaping @Sendable (String) -> Void) async throws -> ToolOutput {
        let path = try arguments.requiredString("path")
        let content = try arguments.requiredString("content")
        let url = try ICloudWorkspace.resolve(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: url, options: .atomic)
        return ToolOutput(forModel: "Saved \(path) (\(content.utf8.count) bytes).", summary: "Saved \(path) to iCloud Drive")
    }
}

// MARK: - Apple Mail, iMessage, Apple Notes, Obsidian & Evernote

private struct AppleMailComposeTool: AppleDescribedTool {
    let configuration: ConnectorConfiguration
    var definition: ConnectorToolDefinition {
        ConnectorToolDefinition(
            serverID: configuration.serverID, serverName: configuration.displayName, originalName: "compose_email",
            title: "Draft in Apple Mail",
            description: "Open a pre-filled email draft in Apple Mail on this iPhone ready for the user to review and tap Send. (iOS sandboxes reading Apple Mail inboxes; use Gmail/Outlook connectors for inbox reading.)",
            inputSchema: [
                "type": "object",
                "properties": [
                    "to": ["type": "string", "description": "Recipient email address."],
                    "subject": ["type": "string", "description": "Email subject line."],
                    "body": ["type": "string", "description": "Plain-text email body."]
                ],
                "required": ["subject", "body"]
            ]
        )
    }
    var name: String { definition.namespacedName }
    var spec: ToolSpec { ToolSpec(name: name, description: definition.description, parameters: definition.inputSchema) }
    func runningSummary(for arguments: JSONValue) -> String { "Opening draft in Apple Mail…" }
    func approvalAfterOutsideContent(for arguments: JSONValue) async -> ToolApprovalRequest? {
        ToolApprovalRequest(question: "Open an email draft in Apple Mail to \(arguments["to"]?.stringValue ?? "recipient")?", allowLabel: "Open Mail")
    }
    func run(arguments: JSONValue, progress: @escaping @Sendable (String) -> Void) async throws -> ToolOutput {
        let to = arguments["to"]?.stringValue ?? ""
        let subject = try arguments.requiredString("subject")
        let body = try arguments.requiredString("body")
        var comp = URLComponents()
        comp.scheme = "mailto"
        comp.path = to
        comp.queryItems = [URLQueryItem(name: "subject", value: subject), URLQueryItem(name: "body", value: body)]
        guard let url = comp.url else { throw ToolInputError("Invalid email fields.") }
        let opened = await MainActor.run { () -> Bool in
            guard UIApplication.shared.canOpenURL(url) else { return false }
            UIApplication.shared.open(url)
            return true
        }
        return ToolOutput(
            forModel: opened ? "Opened pre-filled draft in Apple Mail for user review." : "Prepared draft (Apple Mail app is not configured on this device):\nSubject: \(subject)\n\n\(body)",
            summary: opened ? "Opened draft in Apple Mail" : "Prepared email draft"
        )
    }
}

private struct AppleMessagesComposeTool: AppleDescribedTool {
    let configuration: ConnectorConfiguration
    var definition: ConnectorToolDefinition {
        ConnectorToolDefinition(
            serverID: configuration.serverID, serverName: configuration.displayName, originalName: "compose_imessage",
            title: "Draft in Apple Messages",
            description: "Open a pre-filled text/iMessage draft in Apple Messages ready for the user to tap Send. (iOS sandboxes reading iMessage history.)",
            inputSchema: [
                "type": "object",
                "properties": [
                    "recipient": ["type": "string", "description": "Phone number or Apple ID email (optional)."],
                    "body": ["type": "string", "description": "Message text."]
                ],
                "required": ["body"]
            ]
        )
    }
    var name: String { definition.namespacedName }
    var spec: ToolSpec { ToolSpec(name: name, description: definition.description, parameters: definition.inputSchema) }
    func runningSummary(for arguments: JSONValue) -> String { "Opening draft in Messages…" }
    func approvalAfterOutsideContent(for arguments: JSONValue) async -> ToolApprovalRequest? {
        ToolApprovalRequest(question: "Open a message draft in Apple Messages?", allowLabel: "Open Messages")
    }
    func run(arguments: JSONValue, progress: @escaping @Sendable (String) -> Void) async throws -> ToolOutput {
        let recipient = (arguments["recipient"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""
        let body = try arguments.requiredString("body")
        let encodedBody = body.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let urlString = recipient.isEmpty ? "sms:?body=\(encodedBody)" : "sms:\(recipient)?body=\(encodedBody)"
        guard let url = URL(string: urlString) else { throw ToolInputError("Invalid message URL.") }
        let opened = await MainActor.run { () -> Bool in
            guard UIApplication.shared.canOpenURL(url) else { return false }
            UIApplication.shared.open(url)
            return true
        }
        return ToolOutput(
            forModel: opened ? "Opened pre-filled draft in Apple Messages." : "Prepared message text: \(body)",
            summary: "Opened draft in Messages"
        )
    }
}

private struct AppleNotesShareTool: AppleDescribedTool {
    let configuration: ConnectorConfiguration
    var definition: ConnectorToolDefinition {
        ConnectorToolDefinition(
            serverID: configuration.serverID, serverName: configuration.displayName, originalName: "save_and_share_note",
            title: "Send note to Apple Notes",
            description: "Save a note locally, copy it, and open the iOS Share sheet so the user can save it into Apple Notes in one tap.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "title": ["type": "string", "description": "Note title."],
                    "content": ["type": "string", "description": "Note text / Markdown."]
                ],
                "required": ["title", "content"]
            ]
        )
    }
    var name: String { definition.namespacedName }
    var spec: ToolSpec { ToolSpec(name: name, description: definition.description, parameters: definition.inputSchema) }
    func runningSummary(for arguments: JSONValue) -> String { "Preparing note for Apple Notes…" }
    func approvalAfterOutsideContent(for arguments: JSONValue) async -> ToolApprovalRequest? {
        ToolApprovalRequest(question: "Open iOS Share sheet to save \"\(arguments["title"]?.stringValue ?? "note")\" to Apple Notes?", allowLabel: "Share note")
    }
    func run(arguments: JSONValue, progress: @escaping @Sendable (String) -> Void) async throws -> ToolOutput {
        let title = try arguments.requiredString("title")
        let content = try arguments.requiredString("content")
        let fullText = "\(title)\n\n\(content)"
        await MainActor.run {
            PresentShareSheet.present(text: fullText)
        }
        return ToolOutput(forModel: "Presented note '\(title)' in iOS Share sheet so the user can tap Notes → Save.", summary: "Ready to save '\(title)' in Apple Notes")
    }
}

private struct ObsidianNoteTool: AppleDescribedTool {
    let configuration: ConnectorConfiguration
    var definition: ConnectorToolDefinition {
        ConnectorToolDefinition(
            serverID: configuration.serverID, serverName: configuration.displayName, originalName: "create_obsidian_note",
            title: "Create note in Obsidian",
            description: "Create a Markdown note directly in Obsidian on this iPhone via `obsidian://new` (and save a backup `.md` copy in MAIPA-G's Files folder).",
            inputSchema: [
                "type": "object",
                "properties": [
                    "name": ["type": "string", "description": "Note title / path without .md."],
                    "content": ["type": "string", "description": "Markdown content."],
                    "vault": ["type": "string", "description": "Optional Obsidian vault name."]
                ],
                "required": ["name", "content"]
            ]
        )
    }
    var name: String { definition.namespacedName }
    var spec: ToolSpec { ToolSpec(name: name, description: definition.description, parameters: definition.inputSchema) }
    func runningSummary(for arguments: JSONValue) -> String { "Sending Markdown note to Obsidian…" }
    func approvalAfterOutsideContent(for arguments: JSONValue) async -> ToolApprovalRequest? {
        ToolApprovalRequest(question: "Create Markdown note \"\(arguments["name"]?.stringValue ?? "")\" in Obsidian?", allowLabel: "Create in Obsidian")
    }
    func run(arguments: JSONValue, progress: @escaping @Sendable (String) -> Void) async throws -> ToolOutput {
        let noteName = try arguments.requiredString("name")
        let content = try arguments.requiredString("content")
        let safeFile = noteName.replacingOccurrences(of: "/", with: "-") + ".md"
        if let backupURL = try? ICloudWorkspace.resolve("Obsidian/\(safeFile)") {
            try? FileManager.default.createDirectory(at: backupURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data(content.utf8).write(to: backupURL, options: .atomic)
        }
        var comp = URLComponents()
        comp.scheme = "obsidian"
        comp.host = "new"
        var items = [URLQueryItem(name: "name", value: noteName), URLQueryItem(name: "content", value: content)]
        if let vault = arguments["vault"]?.stringValue, !vault.isEmpty {
            items.append(URLQueryItem(name: "vault", value: vault))
        }
        comp.queryItems = items
        let opened = await MainActor.run { () -> Bool in
            guard let url = comp.url, UIApplication.shared.canOpenURL(url) else { return false }
            UIApplication.shared.open(url)
            return true
        }
        return ToolOutput(
            forModel: opened ? "Opened note '\(noteName)' in Obsidian and saved a backup in Files → MAIPA-G/Obsidian." : "Saved '\(safeFile)' in Files → MAIPA-G/Obsidian (Obsidian app URL scheme was not detected on this device).",
            summary: opened ? "Created '\(noteName)' in Obsidian" : "Saved '\(safeFile)' for Obsidian"
        )
    }
}

private struct EvernoteShareTool: AppleDescribedTool {
    let configuration: ConnectorConfiguration
    var definition: ConnectorToolDefinition {
        ConnectorToolDefinition(
            serverID: configuration.serverID, serverName: configuration.displayName, originalName: "create_evernote_note",
            title: "Send note to Evernote",
            description: "Prepare a formatted note and open Evernote / iOS Share sheet on this iPhone.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "title": ["type": "string", "description": "Note title."],
                    "content": ["type": "string", "description": "Note body."]
                ],
                "required": ["title", "content"]
            ]
        )
    }
    var name: String { definition.namespacedName }
    var spec: ToolSpec { ToolSpec(name: name, description: definition.description, parameters: definition.inputSchema) }
    func runningSummary(for arguments: JSONValue) -> String { "Preparing Evernote note…" }
    func approvalAfterOutsideContent(for arguments: JSONValue) async -> ToolApprovalRequest? {
        ToolApprovalRequest(question: "Share note \"\(arguments["title"]?.stringValue ?? "")\" to Evernote?", allowLabel: "Share")
    }
    func run(arguments: JSONValue, progress: @escaping @Sendable (String) -> Void) async throws -> ToolOutput {
        let title = try arguments.requiredString("title")
        let content = try arguments.requiredString("content")
        await MainActor.run {
            PresentShareSheet.present(text: "\(title)\n\n\(content)")
        }
        return ToolOutput(forModel: "Opened iOS Share sheet with '\(title)' ready for Evernote.", summary: "Prepared '\(title)' for Evernote")
    }
}

@MainActor
private enum PresentShareSheet {
    static func present(text: String) {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
              var top = scene.windows.first(where: \.isKeyWindow)?.rootViewController else { return }
        while let presented = top.presentedViewController { top = presented }
        let activity = UIActivityViewController(activityItems: [text], applicationActivities: nil)
        top.present(activity, animated: true)
    }
}

private enum FlexibleISODateParser {
    static func parse(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        if let d = standard.date(from: trimmed) { return d }

        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = fractional.date(from: trimmed) { return d }

        let localFormats = [
            "yyyy-MM-dd'T'HH:mm:ss",
            "yyyy-MM-dd'T'HH:mm",
            "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-dd HH:mm",
            "yyyy-MM-dd",
        ]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        for pattern in localFormats {
            formatter.dateFormat = pattern
            if let d = formatter.date(from: trimmed) { return d }
        }
        return nil
    }
}
