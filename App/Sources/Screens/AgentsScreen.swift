import AgentCore
import SwiftUI

struct AgentsScreen: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var deletingAgent: CustomAgentRecord?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(filtered) { agent in
                        NavigationLink { AgentDetailScreen(agent: agent) } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(agent.name).font(.body.weight(.semibold))
                                    Text(agent.isBuiltIn ? "Built in" : "Custom")
                                        .font(.caption2)
                                        .foregroundStyle(Theme.secondaryText)
                                }
                                Text(agent.summary).font(.caption).foregroundStyle(Theme.secondaryText).lineLimit(2)
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if let record = app.automations.agentRecord(for: agent) {
                                Button(role: .destructive) { deletingAgent = record } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                .tint(Theme.danger)
                            }
                        }
                    }
                } header: {
                    Text("Specialists with one clear job — tap any agent to give it a task.")
                        .font(.footnote)
                        .foregroundStyle(Theme.secondaryText)
                        .textCase(nil)
                }
            }
            .searchable(text: $query, prompt: "Search agents")
            .navigationTitle("Agents")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    NavigationLink { AgentEditorScreen() } label: { Image(systemName: "plus") }
                        .accessibilityLabel("New agent")
                }
            }
            .alert("Delete this agent?", isPresented: Binding(get: { deletingAgent != nil }, set: { if !$0 { deletingAgent = nil } })) {
                Button("Delete", role: .destructive) {
                    if let record = deletingAgent {
                        deletingAgent = nil
                        Task { await app.automations.deleteAgent(record.id) }
                    }
                }
                Button("Cancel", role: .cancel) { deletingAgent = nil }
            } message: {
                Text("It moves to Recently Deleted for 30 days.")
            }
        }
    }

    private var filtered: [AgentDefinition] {
        guard !query.isEmpty else { return app.automations.agents }
        return app.automations.agents.filter { ($0.name + " " + $0.summary).localizedCaseInsensitiveContains(query) }
    }
}

struct AgentDetailScreen: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let agent: AgentDefinition
    var standalone = false
    @State private var request = ""
    @State private var useRepo = false
    @State private var didSetDefaultTarget = false
    @State private var running = false
    @State private var confirmDelete = false

    private var current: AgentDefinition {
        app.automations.agents.first { $0.id == agent.id } ?? agent
    }

    private var availableRepo: ChatRepo? {
        app.library.openSession?.chat.repo ?? app.home.repo
    }

    private var chosenRepo: ChatRepo? {
        useRepo ? availableRepo : nil
    }

    var body: some View {
        List {
            Section {
                Text(current.summary)
                Label(
                    current.behavior.label,
                    systemImage: current.behavior == .reportOnly || current.behavior == .review ? "doc.text.magnifyingglass" : "hammer"
                )
                .font(.subheadline)
                .foregroundStyle(Theme.secondaryText)
            }

            Section {
                if let repo = availableRepo {
                    Picker("Where it runs", selection: $useRepo) {
                        Text("On this phone").tag(false)
                        Text("\(repo.ref.name) (\(repo.branch))").tag(true)
                    }
                } else {
                    Label("Runs right on this phone", systemImage: "iphone")
                        .font(.footnote)
                        .foregroundStyle(Theme.secondaryText)
                }
                TextField("Tell \(current.name) what you want done…", text: $request, axis: .vertical)
                    .lineLimit(3...8)
                Button {
                    run()
                } label: {
                    HStack(spacing: 8) {
                        if running { ProgressView().controlSize(.small) }
                        Label("Run \(current.name)", systemImage: "play.fill")
                            .font(.body.weight(.semibold))
                    }
                }
                .disabled(running || request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } header: {
                Text("Run this agent")
            } footer: {
                Text("Starts a background run and opens Jobs so you can watch progress and read the finished answer.")
            }

            Section("How it works") {
                Text(current.instructions)
                DisclosureGroup("Allowed tools (\(current.allowedTools.count))") {
                    Text(current.allowedTools.joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryText)
                        .textSelection(.enabled)
                }
            }

            Section {
                if let record = app.automations.agentRecord(for: current) {
                    NavigationLink("Edit agent") { AgentEditorScreen(record: record, template: current) }
                    Button("Make another copy") { Task { _ = await app.automations.duplicate(current) } }
                    Button("Delete agent", role: .destructive) { confirmDelete = true }
                } else {
                    NavigationLink("Customize a copy") { AgentEditorScreen(record: nil, template: current) }
                }
            } footer: {
                if current.isBuiltIn {
                    Text("Built-in agents stay untouched, so customizing saves your own editable copy.")
                }
            }
        }
        .navigationTitle(current.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if standalone {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .onAppear {
            guard !didSetDefaultTarget else { return }
            didSetDefaultTarget = true
            useRepo = availableRepo != nil && app.settings.autonomousEnabled
        }
        .alert("Delete this agent?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) {
                if let record = app.automations.agentRecord(for: current) {
                    Task { await app.automations.deleteAgent(record.id); dismiss() }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It moves to Recently Deleted for 30 days.")
        }
        .alert(
            "Couldn't start agent",
            isPresented: Binding(
                get: { app.automations.lastError != nil },
                set: { if !$0 { app.automations.clearError() } }
            )
        ) {
            Button("OK") { app.automations.clearError() }
        } message: {
            Text(app.automations.lastError ?? "")
        }
    }

    private func run() {
        let trimmed = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !running else { return }
        KeyboardDismiss.dismiss()
        running = true
        let node = WorkflowNode.agent(title: current.name, agent: current.id, instruction: trimmed)
        let workflow = WorkflowDefinition(id: "agent-run:\(UUID().uuidString)", name: current.name, summary: trimmed, steps: [node], isApproved: true)
        Task {
            _ = await app.automations.run(workflow, request: trimmed, repo: chosenRepo)
            running = false
        }
    }
}

extension AgentBehavior {
    var label: String {
        switch self {
        case .reportOnly: return "Read & report only (never changes files)"
        case .changesAllowed: return "Can edit files and run checks"
        case .review: return "Independent review (never changes files)"
        case .pullRequest: return "Opens pull requests"
        case .feedback: return "Handles review feedback"
        case .build: return "Runs builds and checks IPAs"
        }
    }
}
