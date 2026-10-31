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
                    Button("Agent step") { record.steps.append(.agent(title: "New agent step", agent: "general-task-execution", instruction: "Describe this step.")) }
                    Button("Sequence") { record.steps.append(.sequence(title: "Step sequence", steps: [.agent(title: "First step", agent: "context-gatherer", instruction: "Gather context."), .agent(title: "Second step", agent: "general-task-execution", instruction: "Execute using {{first.output}}.")])) }
                    Button("Repeat") { record.steps.append(.repeatUntil(title: "Repeat until done", maximum: 3, goal: "The goal is verified.", steps: [.agent(title: "Work", agent: "general-task-execution", instruction: "Make the next improvement and report GOAL_MET only when verified." )])) }
                    Button("Parallel branches") { record.steps.append(.parallel(title: "Parallel helpers", agents: [.agent(title: "First helper", agent: "context-gatherer", instruction: "Explore independently."), .agent(title: "Second helper", agent: "semantic-reviewer", instruction: "Review independently.")])) }
                    Button("Watch") { record.steps.append(.watch(title: "Watch until ready", instruction: "Check current status and report READY when finished.", containsText: "READY", maximumChecks: 5, pollIntervalSeconds: 5, agent: "context-gatherer")) }
                    Button("Stop and ask") { record.steps.append(.ask(title: "Ask before continuing", question: "Continue?", options: ["Continue", "Stop"])) }
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
    @Environment(AppModel.self) private var app
    @Binding var node: WorkflowNode
    let agents: [AgentDefinition]

    private var eligibleModels: [ModelInfo] {
        Array(app.openRouter.models.filter { !$0.isFree && $0.id != ModelChoice.freeID }.prefix(30))
    }

    var body: some View {
        DisclosureGroup {
            TextField("Step name", text: $node.title)
            if node.kind == .agent {
                Picker("Agent", selection: Binding(get: { node.agentID ?? "planner" }, set: { node.agentID = $0 })) {
                    ForEach(agents) { Text($0.name).tag($0.id) }
                }
                stepModelAndEffortPickers
                TextField("Instructions", text: optional($node.instruction), axis: .vertical)
            } else if node.kind == .sequence {
                ForEach($node.children) { $child in WorkflowStepEditor(node: $child, agents: agents) }
                Button("Add sequence step") { node.children.append(.agent(title: "Next step", agent: "general-task-execution", instruction: "Continue the sequence.")) }
            } else if node.kind == .repeatUntil {
                Stepper("Maximum \(node.maximumIterations ?? 3) rounds", value: Binding(get: { node.maximumIterations ?? 3 }, set: { node.maximumIterations = $0 }), in: 1...50)
                Picker("When max rounds reached", selection: Binding(get: { node.onMaxIterations ?? .pause }, set: { node.onMaxIterations = $0 })) {
                    Text("Pause & ask").tag(RepeatLimitBehavior.pause)
                    Text("Continue").tag(RepeatLimitBehavior.continue)
                    Text("Fail").tag(RepeatLimitBehavior.fail)
                }
                TextField("Goal condition", text: optional($node.successCondition), axis: .vertical)
                TextField("Or output contains text (optional)", text: optional($node.containsText))
                ForEach($node.children) { $child in WorkflowStepEditor(node: $child, agents: agents) }
            } else if node.kind == .watch {
                Picker("Agent", selection: Binding(get: { node.agentID ?? "context-gatherer" }, set: { node.agentID = $0 })) {
                    ForEach(agents) { Text($0.name).tag($0.id) }
                }
                stepModelAndEffortPickers
                TextField("Check instruction", text: optional($node.instruction), axis: .vertical)
                TextField("Stop when output contains", text: optional($node.containsText))
                Stepper("Max \(node.maximumIterations ?? 5) checks", value: Binding(get: { node.maximumIterations ?? 5 }, set: { node.maximumIterations = $0 }), in: 1...50)
            } else if node.kind == .stopAndAsk {
                TextField("Question", text: optional($node.question), axis: .vertical)
                TextField("Choices, separated by commas", text: Binding(get: { node.options.joined(separator: ", ") }, set: { node.options = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }))
            } else if node.kind == .parallel {
                Picker("Join policy", selection: Binding(get: { node.joinPolicy ?? .all }, set: { node.joinPolicy = $0 })) {
                    Text("All succeed").tag(ParallelJoinPolicy.all)
                    Text("All settled").tag(ParallelJoinPolicy.allSettled)
                    Text("Any first success").tag(ParallelJoinPolicy.any)
                }
                ForEach($node.children) { $child in WorkflowStepEditor(node: $child, agents: agents) }
                Button("Add helper") { node.children.append(.agent(title: "Helper", agent: "context-gatherer", instruction: "Work independently and report.")) }
            }
        } label: { Label(node.title, systemImage: node.kind.icon) }
    }

    @ViewBuilder
    private var stepModelAndEffortPickers: some View {
        Picker("AI model", selection: Binding(get: { node.modelID ?? "" }, set: { node.modelID = $0.isEmpty ? nil : $0 })) {
            Text("Chat's active AI").tag("")
            ForEach(eligibleModels) { model in
                Text(model.shortName).tag(model.id)
            }
        }
        Picker("Thinking effort", selection: Binding(get: { node.effortLevel ?? .max }, set: { node.effortLevel = $0 })) {
            Text("Low").tag(ThinkingLevel.low)
            Text("Medium").tag(ThinkingLevel.medium)
            Text("High").tag(ThinkingLevel.high)
            Text("Extra High").tag(ThinkingLevel.xhigh)
            Text("Max").tag(ThinkingLevel.max)
        }
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
                Button {
                    Task { draft = await app.automations.makeWorkflow(description: description) }
                } label: {
                    if app.automations.isMakingWorkflow { ProgressView() }
                    else { Text("Make draft") }
                }
                .disabled(description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || app.automations.isMakingWorkflow)
            }
            Section { Text("Workflow maker turns your words into typed steps. You can edit every step, then you must approve the saved draft before its first run.").font(.caption).foregroundStyle(Theme.secondaryText) }
            if let error = app.automations.lastError { Section { Text(error).foregroundStyle(Theme.danger) } }
            if let draft { Section("Draft") { NavigationLink("Review and edit \(draft.name)") { WorkflowEditorScreen(record: draft) } } }
        }
        .navigationTitle("Workflow maker")
        .navigationBarTitleDisplayMode(.inline)
    }
}
