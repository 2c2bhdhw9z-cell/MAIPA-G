import AgentCore
import SwiftUI

/// The side menu: search, a new chat, every chat grouped by when it was used, and Settings.
struct SideMenu: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @State private var query = ""
    @State private var tab: MenuTab = {
        switch PreviewScenes.scene {
        case "menu-agents": return .agents
        case "menu-workflows": return .workflows
        case "menu-memories": return .memories
        default: return .chats
        }
    }()
    @State private var selected: ChatSummary?
    @State private var showRename = false
    @State private var showDelete = false
    @State private var deletingAgent: CustomAgentRecord?
    @State private var deletingWorkflow: WorkflowRecord?
    @State private var newTitle = ""
    @AccessibilityFocusState(for: .voiceOver) private var newChatFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            tabs
            search
            list
            footer
        }
        .background(Theme.surface.ignoresSafeArea())
        .onChange(of: app.isMenuOpen) { _, isOpen in
            guard isOpen else { return }
            Task { @MainActor in
                await Task.yield()
                newChatFocused = true
            }
        }
        .alert("Rename chat", isPresented: $showRename) {
            TextField("Name", text: $newTitle)
            Button("Save") {
                if let chat = selected { Task { await app.library.rename(chat.id, to: newTitle) } }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Delete this chat?", isPresented: $showDelete) {
            Button("Delete", role: .destructive) {
                if let chat = selected { Task { await app.library.delete(chat.id) } }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It stays in Recently Deleted for 30 days.")
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
            Text("It stays in Recently Deleted for 30 days.")
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
            Text("It stays in Recently Deleted for 30 days.")
        }
    }

    private func rename(_ chat: ChatSummary) {
        selected = chat
        newTitle = chat.title
        showRename = true
    }

    private func delete(_ chat: ChatSummary) {
        selected = chat
        showDelete = true
    }

    private var header: some View {
        HStack(spacing: 10) {
            Spark(size: 34)
            Text("MAIPA-G")
                .font(.rounded(.title3, weight: .bold))
                .accessibilityAddTraits(.isHeader)
            Spacer()
            Button {
                app.newChat()
            } label: {
                Image(systemName: "square.and.pencil")
                    .font(.body.weight(.semibold))
                    .frame(width: 36, height: 36)
                    .background(Theme.raised, in: Circle())
                    .overlay(Circle().strokeBorder(Theme.stroke))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("New chat")
            .accessibilityFocused($newChatFocused)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    private enum MenuTab: String, CaseIterable, Identifiable {
        case chats = "Chats"
        case agents = "Agents"
        case workflows = "Workflows"
        case memories = "Memories"
        var id: String { rawValue }
    }

    private var tabs: some View {
        Picker("Library", selection: $tab) {
            ForEach(MenuTab.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private var search: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(Theme.secondaryText)
            TextField("Search \(tab.rawValue.lowercased())", text: $query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.secondaryText) }
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Theme.sunken, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    @ViewBuilder private var list: some View {
        switch tab {
        case .chats:
            let groups = groupedChats
            List {
                if !app.library.isLoaded {
                    ProgressView().frame(maxWidth: .infinity).listRowBackground(Color.clear)
                } else if groups.isEmpty {
                    Text(query.isEmpty ? "Your chats will show up here." : "No chats match.")
                        .font(.subheadline).foregroundStyle(Theme.secondaryText).listRowBackground(Color.clear)
                }
                ForEach(groups, id: \.id) { group in
                    Section {
                        ForEach(group.chats) { chat in row(chat) }
                    } header: {
                        Text(group.title).font(.caption.weight(.semibold)).foregroundStyle(Theme.secondaryText).textCase(nil)
                    }
                }
            }
            .listStyle(.plain).scrollContentBackground(.hidden).environment(\.defaultMinListRowHeight, 44)
        case .agents:
            let filteredAgents = app.automations.agents.filter { query.isEmpty || ($0.name + " " + $0.summary).localizedCaseInsensitiveContains(query) }
            List {
                Section {
                    if filteredAgents.isEmpty {
                        Text("No agents match.")
                            .font(.subheadline).foregroundStyle(Theme.secondaryText).listRowBackground(Color.clear)
                    }
                    ForEach(filteredAgents) { agent in
                        Button {
                            app.sheet = .agentDetail(agent.id)
                            app.isMenuOpen = false
                        } label: {
                            HStack(spacing: 8) {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(agent.name).font(.subheadline.weight(.medium))
                                        if !agent.isBuiltIn {
                                            Text("Custom").font(.caption2).foregroundStyle(Theme.secondaryText)
                                        }
                                    }
                                    Text(agent.summary).font(.caption).foregroundStyle(Theme.secondaryText).lineLimit(2)
                                }
                                Spacer(minLength: 4)
                                Image(systemName: "chevron.right")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(Theme.secondaryText)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if let record = app.automations.agentRecord(for: agent) {
                                Button(role: .destructive) { deletingAgent = record } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                .tint(Theme.danger)
                            }
                        }
                    }
                    Button {
                        app.sheet = .agents
                        app.isMenuOpen = false
                    } label: {
                        Label("Manage or create agents", systemImage: "slider.horizontal.3")
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                } header: {
                    Text("Specialists for one job — tap one to run it.")
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryText)
                        .textCase(nil)
                }
            }
            .listStyle(.plain).scrollContentBackground(.hidden)
        case .workflows:
            let filteredWorkflows = app.automations.workflows.filter { query.isEmpty || ($0.name + " " + $0.summary).localizedCaseInsensitiveContains(query) }
            List {
                Section {
                    if filteredWorkflows.isEmpty {
                        Text("No workflows match.")
                            .font(.subheadline).foregroundStyle(Theme.secondaryText).listRowBackground(Color.clear)
                    }
                    ForEach(filteredWorkflows) { workflow in
                        Button {
                            app.sheet = .workflowDetail(workflow.id)
                            app.isMenuOpen = false
                        } label: {
                            HStack(spacing: 8) {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(workflow.name).font(.subheadline.weight(.medium))
                                        if !workflow.isBuiltIn {
                                            Text(workflow.isApproved ? "Custom" : "Draft")
                                                .font(.caption2)
                                                .foregroundStyle(Theme.secondaryText)
                                        }
                                    }
                                    Text(workflow.summary).font(.caption).foregroundStyle(Theme.secondaryText).lineLimit(2)
                                }
                                Spacer(minLength: 4)
                                Image(systemName: "chevron.right")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(Theme.secondaryText)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if let record = app.automations.workflowRecord(for: workflow) {
                                Button(role: .destructive) { deletingWorkflow = record } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                .tint(Theme.danger)
                            }
                        }
                    }
                    Button {
                        app.sheet = .workflows
                        app.isMenuOpen = false
                    } label: {
                        Label("Manage or build workflows", systemImage: "slider.horizontal.3")
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                } header: {
                    Text("Step-by-step plans that chain agents — tap one to run it.")
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryText)
                        .textCase(nil)
                }
            }
            .listStyle(.plain).scrollContentBackground(.hidden)
        case .memories:
            let filteredMemories = app.memories.memories.filter { query.isEmpty || $0.text.localizedCaseInsensitiveContains(query) }
            List {
                if filteredMemories.isEmpty {
                    Text(query.isEmpty ? "No memories yet." : "No memories match.")
                        .font(.subheadline).foregroundStyle(Theme.secondaryText).listRowBackground(Color.clear)
                }
                ForEach(filteredMemories) { memory in
                    Button {
                        app.sheet = .memoryEditor(memory.id)
                        app.isMenuOpen = false
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(memory.text).lineLimit(3)
                            Label(memory.source.label, systemImage: memory.source.icon).font(.caption).foregroundStyle(Theme.secondaryText)
                        }
                    }.buttonStyle(.plain)
                    .listRowBackground(Color.clear)
                }
                Button { app.sheet = .memories; app.isMenuOpen = false } label: { Label("Manage memories", systemImage: "slider.horizontal.3") }
                    .listRowBackground(Color.clear)
            }
            .listStyle(.plain).scrollContentBackground(.hidden)
        }
    }

    private func row(_ chat: ChatSummary) -> some View {
        let isOpen = app.library.openSession?.id == chat.id
        let isWorking = app.library.session(chat.id)?.isRunning == true
        return Button {
            Task {
                await app.library.open(chat.id)
                withAnimation(.snappy(duration: 0.3)) { app.isMenuOpen = false }
            }
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(chat.title)
                        .font(.subheadline.weight(isOpen ? .semibold : .regular))
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        if let repo = chat.repoName {
                            Image(systemName: "chevron.left.forwardslash.chevron.right")
                            Text(repo.split(separator: "/").last.map(String.init) ?? repo).lineLimit(1)
                            Text("·")
                        }
                        Text(chat.updatedAt.friendlyAgo)
                    }
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
                }
                Spacer(minLength: 4)
                if isWorking {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(isOpen ? theme.accent.opacity(0.12) : Color.clear)
        .listRowSeparator(.hidden)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) { delete(chat) } label: { Label("Delete", systemImage: "trash") }
                .tint(Theme.danger)
            Button { rename(chat) } label: { Label("Rename", systemImage: "pencil") }
                .tint(.gray)
        }
        .contextMenu {
            Button { rename(chat) } label: { Label("Rename", systemImage: "pencil") }
            Button(role: .destructive) { delete(chat) } label: { Label("Delete", systemImage: "trash") }
        }
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 10) {
                if let login = app.github.login {
                    Image(systemName: "person.crop.circle.fill")
                        .font(.title2)
                        .foregroundStyle(theme.accent)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(login).font(.subheadline.weight(.medium)).lineLimit(1)
                        Text(saveStatus).font(.caption).foregroundStyle(Theme.secondaryText).lineLimit(1)
                        if let credit = openRouterStatus {
                            Text(credit).font(.caption2.monospacedDigit()).foregroundStyle(Theme.secondaryText).lineLimit(1)
                        }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Not connected to GitHub")
                            .font(.subheadline)
                            .foregroundStyle(Theme.secondaryText)
                        if let credit = openRouterStatus {
                            Text(credit).font(.caption2.monospacedDigit()).foregroundStyle(Theme.secondaryText).lineLimit(1)
                        }
                    }
                }
                Spacer()
                Button {
                    app.sheet = .connectors
                    app.isMenuOpen = false
                } label: {
                    Image(systemName: "puzzlepiece.extension")
                        .font(.body.weight(.semibold))
                        .frame(width: 36, height: 36)
                        .background(Theme.raised, in: Circle())
                        .overlay(Circle().strokeBorder(Theme.stroke))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Connectors")
                Button {
                    app.jobs.show()
                } label: {
                    Image(systemName: "gearshape.2")
                        .font(.body.weight(.semibold))
                        .frame(width: 36, height: 36)
                        .background(Theme.raised, in: Circle())
                        .overlay(Circle().strokeBorder(Theme.stroke))
                        .overlay(alignment: .topTrailing) {
                            if app.jobs.activeCount > 0 {
                                Text("\(min(app.jobs.activeCount, 9))")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(.white)
                                    .frame(width: 16, height: 16)
                                    .background(theme.accent, in: Circle())
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Jobs")
                Button {
                    app.sheet = .settings
                } label: {
                    Image(systemName: "gearshape")
                        .font(.body.weight(.semibold))
                        .frame(width: 36, height: 36)
                        .background(Theme.raised, in: Circle())
                        .overlay(Circle().strokeBorder(Theme.stroke))
                        .overlay(alignment: .topTrailing) {
                            if app.updates.newer != nil {
                                Circle().fill(.red).frame(width: 9, height: 9)
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(app.updates.newer != nil ? "Settings, a new build is out" : "Settings")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }

    private var saveStatus: String {
        switch app.sync.status {
        case .off: return "Chats saved on this phone"
        case .idle: return app.sync.lastSaved.map { "Saved \($0.friendlyAgo)" } ?? "Chats saved to GitHub"
        case .saving: return "Saving…"
        case .failed: return "Not saved to GitHub yet"
        }
    }

    private var openRouterStatus: String? {
        guard app.openRouter.isSignedIn else { return nil }
        let balances = app.openRouter.providerBalanceItems
        var items: [String] = []
        if balances.count == 1 {
            items.append(balances[0].balance.dollars)
        } else if balances.count > 1 {
            items.append(contentsOf: balances.prefix(3).map { "\($0.name) \($0.balance.dollars)" })
        }
        if let free = app.openRouter.freeRequestsLeft { items.append("\(free) free") }
        if items.isEmpty, !app.openRouter.readyExternalProviders.isEmpty {
            items.append(app.openRouter.readyExternalProviders.map(\.name).joined(separator: " · "))
        }
        return items.isEmpty ? nil : items.joined(separator: " · ")
    }

    // MARK: Grouping by day

    private struct Group {
        var id: String
        var title: String
        var chats: [ChatSummary]
    }

    private var groupedChats: [Group] {
        let chats = app.library.summaries.filter { $0.matches(query) }
        var result: [Group] = []
        for userGroup in app.groups.groups {
            let members = chats.filter { $0.groupID == userGroup.id }
            if !members.isEmpty { result.append(Group(id: "group-\(userGroup.id.uuidString)", title: userGroup.name, chats: members)) }
        }

        let ungrouped = chats.filter { summary in
            guard let id = summary.groupID else { return true }
            return !app.groups.groups.contains { $0.id == id }
        }
        let calendar = Calendar.current
        let now = Date()
        var order: [String] = []
        var buckets: [String: [ChatSummary]] = [:]
        for chat in ungrouped {
            let title: String
            if calendar.isDateInToday(chat.updatedAt) {
                title = "Today"
            } else if calendar.isDateInYesterday(chat.updatedAt) {
                title = "Yesterday"
            } else if let days = calendar.dateComponents([.day], from: chat.updatedAt, to: now).day, days < 7 {
                title = "This week"
            } else if calendar.isDate(chat.updatedAt, equalTo: now, toGranularity: .month) {
                title = "This month"
            } else {
                title = chat.updatedAt.formatted(.dateTime.month(.wide).year())
            }
            if buckets[title] == nil { order.append(title) }
            buckets[title, default: []].append(chat)
        }
        result += order.map { Group(id: "date-\($0)", title: $0, chats: buckets[$0] ?? []) }
        return result
    }
}
