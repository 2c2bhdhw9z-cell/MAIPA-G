import AgentCore
import SwiftUI

struct SpecsScreen: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    var repo: ChatRepo?
    @State private var title = ""
    @State private var request = ""
    @State private var showingNew = false

    var body: some View {
        NavigationStack {
            List {
                if filtered.isEmpty {
                    ContentUnavailableView("No specs yet", systemImage: "list.clipboard", description: Text(repo == nil ? "Pick a repo before starting a spec." : "Start with what you want to build."))
                }
                ForEach(filtered) { spec in
                    NavigationLink { SpecReviewScreen(specID: spec.id) } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(spec.title).font(.body.weight(.semibold))
                                Spacer()
                                Text(spec.stage.title).font(.caption.weight(.semibold)).foregroundStyle(Theme.secondaryText)
                            }
                            Text(spec.repo.fullName).font(.caption).foregroundStyle(Theme.secondaryText)
                            if spec.stage == .execution || spec.stage == .completed {
                                ProgressView(value: Double(spec.tasks.filter(\.isComplete).count), total: Double(max(spec.tasks.count, 1)))
                            }
                        }
                    }
                }
            }
            .navigationTitle("Specs")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) { Button { showingNew = true } label: { Image(systemName: "plus") }.disabled(repo == nil) }
            }
            .task {
                await app.specs.load(discovering: repo)
                await app.specs.refreshJobs()
            }
            .sheet(isPresented: $showingNew) { newSpec }
        }
    }

    private var filtered: [SpecRecord] {
        guard let repo else { return app.specs.specs }
        return app.specs.specs.filter { $0.repo == repo.ref }
    }

    private var newSpec: some View {
        NavigationStack {
            Form {
                Section("Name") { TextField("Login screen", text: $title) }
                Section("What should it do?") { TextField("Describe the feature and what good looks like…", text: $request, axis: .vertical).lineLimit(5...12) }
                if let repo { Section("Project") { LabeledContent("Repo", value: repo.ref.fullName); LabeledContent("Branch", value: repo.branch) } }
            }
            .navigationTitle("New spec")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showingNew = false } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start") {
                        guard let repo else { return }
                        showingNew = false
                        Task { _ = await app.specs.create(title: title, request: request, repo: repo) }
                    }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
