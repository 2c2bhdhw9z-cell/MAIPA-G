import AgentCore
import SwiftUI

struct SpecsScreen: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    var repo: ChatRepo?
    var startCreating: Bool = false
    @State private var title = ""
    @State private var request = ""
    @State private var showingNew = false
    @State private var didAutoOpenNew = false
    @State private var draftRepo: ChatRepo?
    @State private var availableBranches: [GitHubBranch] = []
    @State private var loadingBranches = false

    private var canCreateSpec: Bool {
        repo != nil || !app.github.repos.isEmpty
    }

    var body: some View {
        NavigationStack {
            List {
                if filtered.isEmpty {
                    ContentUnavailableView(
                        "No specs yet",
                        systemImage: "list.clipboard",
                        description: Text(canCreateSpec ? "Tap + to start a structured spec for your feature." : "Connect GitHub in Settings before starting a spec.")
                    )
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
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        seedDraftRepo()
                        showingNew = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .disabled(!canCreateSpec)
                }
            }
            .task {
                if startCreating && !didAutoOpenNew {
                    didAutoOpenNew = true
                    if canCreateSpec {
                        seedDraftRepo()
                        showingNew = true
                    }
                }
                await app.specs.load(discovering: repo)
                await app.specs.refreshJobs()
            }
            .sheet(isPresented: $showingNew) { newSpec }
        }
    }

    private func seedDraftRepo() {
        if let repo {
            draftRepo = repo
        } else if draftRepo == nil, let first = app.github.repos.first {
            draftRepo = ChatRepo(ref: first.ref, branch: first.defaultBranch, defaultBranch: first.defaultBranch, isPrivate: first.isPrivate)
        }
        Task { await loadDraftBranches() }
    }

    private func loadDraftBranches() async {
        guard let selected = draftRepo else {
            availableBranches = []
            return
        }
        loadingBranches = true
        defer { loadingBranches = false }
        if let loaded = try? await app.github.branches(of: selected.ref, refresh: false) {
            availableBranches = loaded
        } else {
            availableBranches = []
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
                Section("What should it do?") {
                    TextField("Describe the feature and what good looks like…", text: $request, axis: .vertical)
                        .lineLimit(5...12)
                }
                Section("Project") {
                    Menu {
                        ForEach(app.github.repos) { candidate in
                            Button {
                                draftRepo = ChatRepo(
                                    ref: candidate.ref,
                                    branch: candidate.defaultBranch,
                                    defaultBranch: candidate.defaultBranch,
                                    isPrivate: candidate.isPrivate
                                )
                                Task { await loadDraftBranches() }
                            } label: {
                                if draftRepo?.ref == candidate.ref {
                                    Label(candidate.fullName, systemImage: "checkmark")
                                } else {
                                    Text(candidate.fullName)
                                }
                            }
                        }
                    } label: {
                        HStack {
                            Text("Repo")
                                .foregroundStyle(.primary)
                            Spacer()
                            Text(draftRepo?.ref.fullName ?? "Choose repo")
                                .foregroundStyle(Theme.secondaryText)
                                .lineLimit(1)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Theme.secondaryText)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if let currentRepo = draftRepo {
                        Menu {
                            let branchNames = availableBranches.isEmpty
                                ? [currentRepo.defaultBranch]
                                : availableBranches.map(\.name)
                            ForEach(branchNames, id: \.self) { name in
                                Button {
                                    draftRepo?.branch = name
                                } label: {
                                    if currentRepo.branch == name {
                                        Label(name, systemImage: "checkmark")
                                    } else {
                                        Text(name)
                                    }
                                }
                            }
                        } label: {
                            HStack {
                                Text("Branch")
                                    .foregroundStyle(.primary)
                                Spacer()
                                if loadingBranches && availableBranches.isEmpty {
                                    ProgressView().controlSize(.mini)
                                }
                                Text(currentRepo.branch)
                                    .foregroundStyle(Theme.secondaryText)
                                    .lineLimit(1)
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(Theme.secondaryText)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle("New spec")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                if draftRepo == nil { seedDraftRepo() }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showingNew = false } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start") {
                        guard let chosenRepo = draftRepo ?? repo else { return }
                        showingNew = false
                        Task { _ = await app.specs.create(title: title, request: request, repo: chosenRepo) }
                    }
                    .disabled(
                        (draftRepo ?? repo) == nil
                            || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                }
            }
        }
    }
}
