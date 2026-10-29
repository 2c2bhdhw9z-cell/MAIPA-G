import AgentCore
import SwiftUI

struct WorkflowsScreen: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    var body: some View {
        NavigationStack {
            List {
                ForEach(filtered) { workflow in
                    NavigationLink { WorkflowDetailScreen(workflow: workflow) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack { Text(workflow.name).font(.body.weight(.semibold)); if workflow.isBuiltIn { Text("Built in").font(.caption2).foregroundStyle(Theme.secondaryText) } }
                            Text(workflow.summary).font(.caption).foregroundStyle(Theme.secondaryText).lineLimit(2)
                        }
                    }
                }
            }
            .searchable(text: $query, prompt: "Search workflows")
            .navigationTitle("Workflows")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItemGroup(placement: .primaryAction) {
                    NavigationLink { WorkflowMakerScreen() } label: { Image(systemName: "wand.and.stars") }.accessibilityLabel("Describe a workflow")
                    NavigationLink { WorkflowEditorScreen() } label: { Image(systemName: "plus") }.accessibilityLabel("Build a workflow")
                }
            }
        }
    }

    private var filtered: [WorkflowDefinition] {
        guard !query.isEmpty else { return app.automations.workflows }
        return app.automations.workflows.filter { ($0.name + " " + $0.summary).localizedCaseInsensitiveContains(query) }
    }
}

private struct WorkflowDetailScreen: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let workflow: WorkflowDefinition
    @State private var request = ""
    @State private var confirmDelete = false

    var body: some View {
        List {
            Section { Text(workflow.summary) }
            Section("Steps") { ForEach(workflow.steps) { WorkflowStepSummary(node: $0) } }
            Section("Run") {
                TextField("What should this workflow do?", text: $request, axis: .vertical)
                if !workflow.isApproved { Label("Approve this draft before its first run.", systemImage: "hand.raised").foregroundStyle(Theme.secondaryText) }
                Button("Run workflow") { Task { await app.automations.run(workflow, request: request) } }
                    .disabled(request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !workflow.isApproved)
            }
            Section {
                NavigationLink("Edit a copy") { WorkflowEditorScreen(record: app.automations.workflowRecord(for: workflow), template: workflow) }
                Button("Duplicate") { Task { _ = await app.automations.duplicate(workflow) } }
                if let record = app.automations.workflowRecord(for: workflow) {
                    if !record.isApproved { Button("Approve workflow") { Task { await app.automations.approve(record) } } }
                    Button("Delete", role: .destructive) { confirmDelete = true }
                        .confirmationDialog("Delete this workflow?", isPresented: $confirmDelete) {
                            Button("Delete", role: .destructive) { Task { await app.automations.deleteWorkflow(record.id); dismiss() } }
                        }
                }
            }
        }
        .navigationTitle(workflow.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct WorkflowStepSummary: View {
    let node: WorkflowNode
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: node.kind.icon).frame(width: 22).foregroundStyle(Theme.secondaryText)
            VStack(alignment: .leading, spacing: 3) {
                Text(node.title)
                Text(node.kind.label).font(.caption).foregroundStyle(Theme.secondaryText)
                ForEach(node.children) { child in Text("• \(child.title)").font(.caption).foregroundStyle(Theme.secondaryText) }
            }
        }
    }
}

extension WorkflowNode.Kind {
    var label: String {
        switch self { case .agent: return "Agent"; case .sequence: return "Sequence"; case .repeatUntil: return "Repeat"; case .stopAndAsk: return "Stop and ask"; case .parallel: return "Parallel helpers" }
    }
    var icon: String {
        switch self { case .agent: return "person.crop.circle"; case .sequence: return "list.number"; case .repeatUntil: return "repeat"; case .stopAndAsk: return "person.crop.circle.badge.questionmark"; case .parallel: return "person.2" }
    }
}
