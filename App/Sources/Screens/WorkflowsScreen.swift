import AgentCore
import SwiftUI

struct WorkflowsScreen: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var deletingWorkflow: WorkflowRecord?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(filtered) { workflow in
                        NavigationLink { WorkflowDetailScreen(workflow: workflow) } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(workflow.name).font(.body.weight(.semibold))
                                    Text(workflow.isBuiltIn ? "Built in" : (workflow.isApproved ? "Custom" : "Draft"))
                                        .font(.caption2)
                                        .foregroundStyle(Theme.secondaryText)
                                }
                                Text(workflow.summary).font(.caption).foregroundStyle(Theme.secondaryText).lineLimit(2)
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if let record = app.automations.workflowRecord(for: workflow) {
                                Button(role: .destructive) { deletingWorkflow = record } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                .tint(Theme.danger)
                            }
                        }
                    }
                } header: {
                    Text("Step-by-step plans that chain specialist agents together — tap any workflow to run it.")
                        .font(.footnote)
                        .foregroundStyle(Theme.secondaryText)
                        .textCase(nil)
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
            .alert("Delete this workflow?", isPresented: Binding(get: { deletingWorkflow != nil }, set: { if !$0 { deletingWorkflow = nil } })) {
                Button("Delete", role: .destructive) {
                    if let record = deletingWorkflow {
                        deletingWorkflow = nil
                        Task { await app.automations.deleteWorkflow(record.id) }
                    }
                }
                Button("Cancel", role: .cancel) { deletingWorkflow = nil }
            } message: {
                Text("It moves to Recently Deleted for 30 days.")
            }
        }
    }

    private var filtered: [WorkflowDefinition] {
        guard !query.isEmpty else { return app.automations.workflows }
        return app.automations.workflows.filter { ($0.name + " " + $0.summary).localizedCaseInsensitiveContains(query) }
    }
}

struct WorkflowDetailScreen: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let workflow: WorkflowDefinition
    var standalone = false
    @State private var request = ""
    @State private var useRepo = false
    @State private var didSetDefaultTarget = false
    @State private var running = false
    @State private var confirmDelete = false

    private var current: WorkflowDefinition {
        app.automations.workflows.first { $0.id == workflow.id } ?? workflow
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
            }

            Section {
                if !current.isApproved {
                    Label("Approve this custom draft once before running it.", systemImage: "hand.raised")
                        .font(.footnote)
                        .foregroundStyle(Theme.secondaryText)
                    if let record = app.automations.workflowRecord(for: current) {
                        Button("Approve workflow") {
                            Task { await app.automations.approve(record) }
                        }
                    }
                }
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
                TextField("Tell this workflow what you want done…", text: $request, axis: .vertical)
                    .lineLimit(3...8)
                Button {
                    run()
                } label: {
                    HStack(spacing: 8) {
                        if running { ProgressView().controlSize(.small) }
                        Label("Run workflow", systemImage: "play.fill")
                            .font(.body.weight(.semibold))
                    }
                }
                .disabled(running || request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !current.isApproved)
            } header: {
                Text("Run this workflow")
            } footer: {
                Text("Runs each step in order and opens Jobs so you can follow along, answer any check-in questions, and read the finished report.")
            }

            Section("Steps in order") {
                ForEach(current.steps) { WorkflowStepSummary(node: $0) }
            }

            Section {
                if let record = app.automations.workflowRecord(for: current) {
                    NavigationLink("Edit workflow") { WorkflowEditorScreen(record: record, template: current) }
                    Button("Make another copy") { Task { _ = await app.automations.duplicate(current) } }
                    Button("Delete workflow", role: .destructive) { confirmDelete = true }
                } else {
                    NavigationLink("Customize a copy") { WorkflowEditorScreen(record: nil, template: current) }
                }
            } footer: {
                if current.isBuiltIn {
                    Text("Built-in workflows stay untouched, so customizing saves your own editable copy.")
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
        .alert("Delete this workflow?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) {
                if let record = app.automations.workflowRecord(for: current) {
                    Task { await app.automations.deleteWorkflow(record.id); dismiss() }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It moves to Recently Deleted for 30 days.")
        }
        .alert(
            "Couldn't start workflow",
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
        guard !trimmed.isEmpty, current.isApproved, !running else { return }
        KeyboardDismiss.dismiss()
        running = true
        Task {
            _ = await app.automations.run(current, request: trimmed, repo: chosenRepo)
            running = false
        }
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
