import AgentCore
import SwiftUI

struct WorkflowEditorScreen: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var record: WorkflowRecord
    @State private var errors: [String] = []

    init(record: WorkflowRecord? = nil, template: WorkflowDefinition? = nil) {
        let value = record ?? WorkflowRecord(
            name: template.map { "\($0.name) copy" } ?? "",
            summary: template?.summary ?? "",
            steps: template?.steps ?? [],
            isApproved: false
        )
        _record = State(initialValue: value)
    }

    var body: some View {
        Form {
            Section("Workflow") {
                TextField("Name", text: $record.name)
                TextField("What it does", text: $record.summary, axis: .vertical)
                if !record.isApproved { Label("Saving makes an editable draft. Approve it from its detail screen before running it.", systemImage: "hand.raised").font(.caption).foregroundStyle(Theme.secondaryText) }
            }
            Section("Steps") {
                ForEach($record.steps) { $step in WorkflowStepEditor(node: $step, agents: app.automations.agents) }
                    .onMove { record.steps.move(fromOffsets: $0, toOffset: $1) }
                    .onDelete { record.steps.remove(atOffsets: $0) }
                Menu("Add step", systemImage: "plus") {
                    Button("Agent") { record.steps.append(.agent(title: "New agent step", agent: "planner", instruction: "Describe this step.")) }
                    Button("Repeat") { record.steps.append(.repeatUntil(title: "Repeat until done", maximum: 3, goal: "The goal is verified.", steps: [.agent(title: "Work", agent: "coder", instruction: "Make the next improvement and report GOAL_MET only when verified." )])) }
                    Button("Stop and ask") { record.steps.append(.ask(title: "Ask before continuing", question: "Continue?", options: ["Continue", "Stop"])) }
                    Button("Parallel helpers") { record.steps.append(.parallel(title: "Parallel helpers", agents: [.agent(title: "First helper", agent: "code-checker", instruction: "Review independently."), .agent(title: "Second helper", agent: "second-opinion", instruction: "Review independently with a different AI.")])) }
                }
            }
            if !errors.isEmpty { Section("Fix before saving") { ForEach(errors, id: \.self) { Text($0).foregroundStyle(Theme.danger) } } }
        }
        .environment(\.editMode, .constant(.active))
        .navigationTitle(record.name.isEmpty ? "New workflow" : record.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.disabled(record.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) } }
    }

    private func save() {
        let definition = record.definition
        errors = definition.validationErrors(agentIDs: Set(app.automations.agents.map(\.id)))
        guard errors.isEmpty else { return }
        record.isApproved = false
        Task { if await app.automations.saveWorkflow(record) != nil { dismiss() } }
    }
}

private struct WorkflowStepEditor: View {
    @Binding var node: WorkflowNode
    let agents: [AgentDefinition]

    var body: some View {
        DisclosureGroup {
            TextField("Step name", text: $node.title)
            if node.kind == .agent {
                Picker("Agent", selection: Binding(get: { node.agentID ?? "planner" }, set: { node.agentID = $0 })) {
                    ForEach(agents) { Text($0.name).tag($0.id) }
                }
                TextField("Instructions", text: optional($node.instruction), axis: .vertical)
            } else if node.kind == .repeatUntil {
                Stepper("Maximum \(node.maximumIterations ?? 3) rounds", value: Binding(get: { node.maximumIterations ?? 3 }, set: { node.maximumIterations = $0 }), in: 1...50)
                TextField("Goal", text: optional($node.successCondition), axis: .vertical)
                ForEach($node.children) { $child in WorkflowStepEditor(node: $child, agents: agents) }
            } else if node.kind == .stopAndAsk {
                TextField("Question", text: optional($node.question), axis: .vertical)
                TextField("Choices, separated by commas", text: Binding(get: { node.options.joined(separator: ", ") }, set: { node.options = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }))
            } else if node.kind == .parallel {
                ForEach($node.children) { $child in WorkflowStepEditor(node: $child, agents: agents) }
                Button("Add helper") { node.children.append(.agent(title: "Helper", agent: "investigator", instruction: "Work independently and report.")) }
            }
        } label: { Label(node.title, systemImage: node.kind.icon) }
    }

    private func optional(_ value: Binding<String?>) -> Binding<String> {
        Binding(get: { value.wrappedValue ?? "" }, set: { value.wrappedValue = $0 })
    }
}

struct WorkflowMakerScreen: View {
    @Environment(AppModel.self) private var app
    @State private var description = ""
    @State private var draft: WorkflowRecord?

    var body: some View {
        Form {
            Section("Describe it") {
                TextField("Example: Plan and build a feature, then have two AIs review it", text: $description, axis: .vertical).lineLimit(4...10)
                Button("Make draft") {
                    let definition = WorkflowDraftBuilder.initialDraft(description: description)
                    draft = WorkflowRecord(definition: definition)
                }.disabled(description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Section { Text("Workflow maker turns your words into typed steps. You can edit every step, then you must approve the saved draft before its first run.").font(.caption).foregroundStyle(Theme.secondaryText) }
            if let draft { Section("Draft") { NavigationLink("Review and edit \(draft.name)") { WorkflowEditorScreen(record: draft) } } }
        }
        .navigationTitle("Workflow maker")
        .navigationBarTitleDisplayMode(.inline)
    }
}
