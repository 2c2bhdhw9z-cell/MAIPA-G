import AgentCore
import SwiftUI

struct AgentsScreen: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    var body: some View {
        NavigationStack {
            List {
                ForEach(filtered) { agent in
                    NavigationLink { AgentDetailScreen(agent: agent) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack { Text(agent.name).font(.body.weight(.semibold)); if agent.isBuiltIn { Text("Built in").font(.caption2).foregroundStyle(Theme.secondaryText) } }
                            Text(agent.summary).font(.caption).foregroundStyle(Theme.secondaryText).lineLimit(2)
                        }
                    }
                }
            }
            .searchable(text: $query, prompt: "Search agents")
            .navigationTitle("Agents")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) { NavigationLink { AgentEditorScreen() } label: { Image(systemName: "plus") } }
            }
        }
    }

    private var filtered: [AgentDefinition] {
        guard !query.isEmpty else { return app.automations.agents }
        return app.automations.agents.filter { ($0.name + " " + $0.summary).localizedCaseInsensitiveContains(query) }
    }
}

private struct AgentDetailScreen: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let agent: AgentDefinition
    @State private var request = ""
    @State private var confirmDelete = false

    var body: some View {
        List {
            Section { Text(agent.summary); Label(agent.behavior.label, systemImage: agent.behavior == .reportOnly || agent.behavior == .review ? "doc.text.magnifyingglass" : "hammer") }
            Section("Role") { Text(agent.instructions) }
            Section("Run") {
                TextField("What should this agent do?", text: $request, axis: .vertical)
                Button("Run agent") { run() }.disabled(request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Section("Tools") { Text(agent.allowedTools.joined(separator: ", ")).font(.caption).textSelection(.enabled) }
            Section {
                NavigationLink("Edit a copy") { AgentEditorScreen(record: app.automations.agentRecord(for: agent), template: agent) }
                Button("Duplicate") { Task { _ = await app.automations.duplicate(agent) } }
                if let record = app.automations.agentRecord(for: agent) {
                    Button("Delete", role: .destructive) { confirmDelete = true }
                        .confirmationDialog("Delete this agent?", isPresented: $confirmDelete) {
                            Button("Delete", role: .destructive) { Task { await app.automations.deleteAgent(record.id); dismiss() } }
                        }
                }
            }
        }
        .navigationTitle(agent.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func run() {
        let node = WorkflowNode.agent(title: agent.name, agent: agent.id, instruction: request)
        let workflow = WorkflowDefinition(id: "agent-run:\(UUID().uuidString)", name: agent.name, summary: request, steps: [node], isApproved: true)
        Task { await app.automations.run(workflow, request: request) }
    }
}

extension AgentBehavior {
    var label: String {
        switch self {
        case .reportOnly: return "Report only"
        case .changesAllowed: return "Can make changes"
        case .review: return "Independent review"
        case .pullRequest: return "Pull requests"
        case .feedback: return "Review feedback"
        case .build: return "Build and IPA checks"
        }
    }
}
