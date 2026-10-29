import AgentCore
import SwiftUI

struct AgentEditorScreen: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var record: CustomAgentRecord
    @State private var tools: String

    init(record: CustomAgentRecord? = nil, template: AgentDefinition? = nil) {
        let value = record ?? CustomAgentRecord(
            name: template.map { "\($0.name) copy" } ?? "",
            summary: template?.summary ?? "",
            instructions: template?.instructions ?? "",
            allowedTools: template?.allowedTools ?? ["list_files", "search_code", "read_file", "ask_user"],
            difficulty: template?.difficulty ?? .normal,
            modelPolicy: template?.modelPolicy ?? .automatic,
            behavior: template?.behavior ?? .reportOnly,
            maximumHelpers: template?.maximumHelpers ?? 0
        )
        _record = State(initialValue: value)
        _tools = State(initialValue: value.allowedTools.joined(separator: ", "))
    }

    var body: some View {
        Form {
            Section("Agent") {
                TextField("Name", text: $record.name)
                TextField("Short description", text: $record.summary, axis: .vertical)
                TextField("Role instructions", text: $record.instructions, axis: .vertical).lineLimit(5...12)
            }
            Section("Policy") {
                Picker("Work", selection: $record.behavior) {
                    ForEach(AgentBehavior.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Picker("Difficulty", selection: $record.difficulty) {
                    ForEach(TaskDifficulty.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }
                Picker("AI", selection: $record.modelPolicy) {
                    ForEach(AgentModelPolicy.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Stepper("Up to \(record.maximumHelpers) helpers", value: $record.maximumHelpers, in: 0...6)
            }
            Section("Allowed tools") {
                TextField("Comma-separated tool names", text: $tools, axis: .vertical)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Text("Report-only and review agents cannot use changing tools even if one is entered here.")
                    .font(.caption).foregroundStyle(Theme.secondaryText)
            }
        }
        .navigationTitle(record.name.isEmpty ? "New agent" : record.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.disabled(!canSave) } }
    }

    private var canSave: Bool {
        !record.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !record.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func save() {
        record.allowedTools = tools.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        Task { if await app.automations.saveAgent(record) != nil { dismiss() } }
    }
}

private extension AgentModelPolicy {
    var label: String {
        switch self {
        case .automatic: return "Auto"
        case .strong: return "Stronger AI"
        case .fast: return "Faster AI"
        case .differentFromPrimary: return "Different AI"
        }
    }
}
