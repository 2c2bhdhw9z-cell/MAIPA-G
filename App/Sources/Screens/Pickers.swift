import AgentCore
import SwiftUI

/// Choose the AI: Auto, the free AIs, or any of OpenRouter's models.
struct ModelPicker: View {
    var target: ComposerTarget
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @State private var query = ""
    @State private var filter: Filter = .all

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", free = "Free", thinks = "Thinks", readsRepos = "Reads repos"
        var id: String { rawValue }
    }

    var body: some View {
        let current = app.model(for: target)
        NavigationStack {
            List {
                if query.isEmpty {
                    Section {
                        choiceRow(.auto, title: "Auto", detail: autoDetail, icon: "wand.and.stars", current: current)
                        choiceRow(.free, title: "Free AIs", detail: freeDetail, icon: "gift", current: current)
                    } footer: {
                        if let left = app.openRouter.freeRequestsLeft {
                            Text("Free AI requests left today: \(left). Each step of an answer is one request.")
                        }
                    }
                }
                Section {
                    Picker("Show", selection: $filter) {
                        ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                }
                ForEach(groups, id: \.maker) { group in
                    Section(group.maker) {
                        ForEach(group.models) { model in
                            modelRow(model, current: current)
                        }
                    }
                }
                if app.openRouter.models.isEmpty {
                    Section {
                        HStack {
                            ProgressView()
                            Text("Getting the list of AIs…").foregroundStyle(Theme.secondaryText)
                        }
                    }
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search AIs")
            .navigationTitle("Choose an AI")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .task { await app.openRouter.loadModels() }
        }
        .presentationDragIndicator(.visible)
    }

    private var autoDetail: String {
        if !app.openRouter.accountState.paidAllowed() { return "Picks for each job. Using free AIs while there's no credit." }
        return "Picks the AI for each job: cheaper ones for easy things, smarter ones for hard work."
    }

    private var freeDetail: String { "Costs nothing. OpenRouter picks a free AI each time." }

    private struct Group {
        var maker: String
        var models: [ModelInfo]
    }

    private var groups: [Group] {
        let filtered = app.openRouter.models.filter { model in
            guard !model.isRouter else { return false }
            switch filter {
            case .all: break
            case .free: if !model.isFree { return false }
            case .thinks: if model.thinkingLevels.isEmpty { return false }
            case .readsRepos: if !model.supportsTools { return false }
            }
            guard !query.isEmpty else { return true }
            return model.name.localizedCaseInsensitiveContains(query) || model.id.localizedCaseInsensitiveContains(query)
        }
        var order: [String] = []
        var buckets: [String: [ModelInfo]] = [:]
        for model in filtered.sorted(by: { ($0.created ?? .distantPast) > ($1.created ?? .distantPast) }) {
            if buckets[model.maker] == nil { order.append(model.maker) }
            buckets[model.maker, default: []].append(model)
        }
        // Makers with the newest models first; within each, newest first.
        return order.map { Group(maker: $0, models: buckets[$0] ?? []) }
    }

    private func choiceRow(_ choice: ModelChoice, title: String, detail: String, icon: String, current: ModelChoice) -> some View {
        Button {
            app.choose(model: choice, for: target)
            dismiss()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(theme.accent)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.body.weight(.semibold))
                    Text(detail).font(.footnote).foregroundStyle(Theme.secondaryText)
                }
                Spacer()
                if current == choice { Image(systemName: "checkmark").foregroundStyle(theme.accent) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func modelRow(_ model: ModelInfo, current: ModelChoice) -> some View {
        let cantReadRepo = app.repo(for: target) != nil && !model.supportsTools
        return Button {
            app.choose(model: .model(model.id), for: target)
            dismiss()
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.shortName).font(.body)
                    HStack(spacing: 6) {
                        Text(price(model))
                        if !model.thinkingLevels.isEmpty { Label("Thinks", systemImage: "brain").labelStyle(.titleAndIcon) }
                        if let context = model.contextLength { Text("holds \(Self.tokens(context))") }
                        if cantReadRepo { Text("Can't read repos").foregroundStyle(Theme.danger) }
                    }
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
                }
                Spacer()
                if current == .model(model.id) { Image(systemName: "checkmark").foregroundStyle(theme.accent) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// "128K", "1M", "1.5M": how much a model can read at once.
    static func tokens(_ count: Int) -> String {
        if count >= 1_000_000 {
            let millions = Double(count) / 1_000_000
            let text = String(format: "%.1f", millions)
            return (text.hasSuffix(".0") ? String(text.dropLast(2)) : text) + "M"
        }
        return "\(max(1, count / 1000))K"
    }

    /// Dollars per million tokens (about 750,000 words), in and out.
    private func price(_ model: ModelInfo) -> String {
        if model.isFree { return "Free" }
        guard let input = model.promptPrice, let output = model.completionPrice else { return "Price varies" }
        func dollars(_ perToken: Double) -> String {
            let perMillion = perToken * 1_000_000
            if perMillion >= 10 { return String(format: "$%.0f", perMillion) }
            if perMillion >= 1 { return String(format: "$%.2g", perMillion) }
            return String(format: "$%.2f", perMillion)
        }
        return "\(dollars(input)) in / \(dollars(output)) out per 1M"
    }
}

/// Choose the repo for a chat.
struct RepoPicker: View {
    var target: ComposerTarget
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.theme) private var theme
    @State private var query = ""

    var body: some View {
        let current = app.repo(for: target)
        NavigationStack {
            List {
                Section {
                    Button {
                        app.choose(repo: nil, for: target)
                        dismiss()
                    } label: {
                        HStack {
                            Label("No repo", systemImage: "bubble.left")
                            Spacer()
                            if current == nil { Image(systemName: "checkmark").foregroundStyle(theme.accent) }
                        }
                    }
                    .buttonStyle(.plain)
                }
                Section {
                    ForEach(filtered) { repo in
                        Button {
                            app.choose(repo: repo, for: target)
                            dismiss()
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: repo.isPrivate ? "lock" : "chevron.left.forwardslash.chevron.right")
                                    .foregroundStyle(Theme.secondaryText)
                                    .frame(width: 22)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(repo.ownerLogin == app.github.login ? repo.name : repo.fullName).font(.body)
                                    HStack(spacing: 6) {
                                        if let language = repo.language { Text(language) }
                                        if let pushed = repo.pushedAt { Text("updated \(pushed.friendlyAgo)") }
                                    }
                                    .font(.caption)
                                    .foregroundStyle(Theme.secondaryText)
                                }
                                Spacer()
                                if current?.ref == repo.ref { Image(systemName: "checkmark").foregroundStyle(theme.accent) }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    if app.github.isLoadingRepos, app.github.repos.isEmpty {
                        HStack { ProgressView(); Text("Getting your repos…").foregroundStyle(Theme.secondaryText) }
                    }
                    if let error = app.github.reposError {
                        Text(error).font(.footnote).foregroundStyle(Theme.danger)
                    }
                } footer: {
                    if let url = app.github.installationSettingsURL {
                        Button("Missing a repo? Let MAIPA-G into more of them") { openURL(url) }
                            .font(.footnote)
                    }
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search repos")
            .refreshable { await app.github.loadRepos() }
            .navigationTitle("Choose a repo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .task { await app.github.loadRepos() }
        }
        .presentationDragIndicator(.visible)
    }

    private var filtered: [GitHubRepo] {
        let repos = app.github.repos.filter { $0.name != DataRepoSync.repoName }
        guard !query.isEmpty else { return repos }
        return repos.filter { $0.fullName.localizedCaseInsensitiveContains(query) || ($0.summary ?? "").localizedCaseInsensitiveContains(query) }
    }
}

/// Choose the branch for a chat's repo.
struct BranchPicker: View {
    var target: ComposerTarget
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @State private var query = ""
    @State private var branches: [GitHubBranch] = []
    @State private var error: String?
    @State private var loading = true

    var body: some View {
        let repo = app.repo(for: target)
        NavigationStack {
            List {
                if let repo {
                    ForEach(filtered(repo)) { branch in
                        Button {
                            app.choose(branch: branch.name, for: target)
                            dismiss()
                        } label: {
                            HStack {
                                Image(systemName: "arrow.triangle.branch").foregroundStyle(Theme.secondaryText)
                                Text(branch.name)
                                if branch.name == repo.defaultBranch {
                                    Text("default")
                                        .font(.caption2.weight(.semibold))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(theme.accent.opacity(0.18), in: Capsule())
                                }
                                Spacer()
                                if repo.branch == branch.name { Image(systemName: "checkmark").foregroundStyle(theme.accent) }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    if loading { HStack { ProgressView(); Text("Getting branches…").foregroundStyle(Theme.secondaryText) } }
                    if let error { Text(error).font(.footnote).foregroundStyle(Theme.danger) }
                } else {
                    Text("Choose a repo first.").foregroundStyle(Theme.secondaryText)
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search branches")
            .navigationTitle(repo?.ref.name ?? "Branches")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .task { await load(repo) }
            .refreshable { await load(repo, refresh: true) }
        }
        .presentationDragIndicator(.visible)
    }

    private func load(_ repo: ChatRepo?, refresh: Bool = false) async {
        guard let repo else { loading = false; return }
        loading = true
        defer { loading = false }
        do {
            branches = try await app.github.branches(of: repo.ref, refresh: refresh)
            error = nil
        } catch {
            self.error = app.github.describe(error)
        }
    }

    private func filtered(_ repo: ChatRepo) -> [GitHubBranch] {
        let sorted = branches.sorted { a, b in
            if a.name == repo.defaultBranch { return true }
            if b.name == repo.defaultBranch { return false }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        guard !query.isEmpty else { return sorted }
        return sorted.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }
}
