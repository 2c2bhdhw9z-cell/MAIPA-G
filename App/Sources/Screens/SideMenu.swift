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
        .confirmationDialog("Delete this chat?", isPresented: $showDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let chat = selected { Task { await app.library.delete(chat.id) } }
            }
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
            automationList(
                app.automations.agents.filter { query.isEmpty || ($0.name + " " + $0.summary).localizedCaseInsensitiveContains(query) },
                empty: "No agents match."
            ) { agent in app.sheet = .agentEditor(agent.id) }
        case .workflows:
            automationList(
                app.automations.workflows.filter { query.isEmpty || ($0.name + " " + $0.summary).localizedCaseInsensitiveContains(query) },
                empty: "No workflows match."
            ) { workflow in app.sheet = .workflowEditor(workflow.id) }
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

    private func automationList<Item: Identifiable>(_ items: [Item], empty: String, action: @escaping (Item) -> Void) -> some View where Item.ID == String {
        List {
            if items.isEmpty { Text(empty).font(.subheadline).foregroundStyle(Theme.secondaryText).listRowBackground(Color.clear) }
            ForEach(items) { item in
                Button { action(item); app.isMenuOpen = false } label: {
                    if let agent = item as? AgentDefinition {
                        VStack(alignment: .leading, spacing: 2) { Text(agent.name); Text(agent.summary).font(.caption).foregroundStyle(Theme.secondaryText).lineLimit(2) }
                    } else if let workflow = item as? WorkflowDefinition {
                        VStack(alignment: .leading, spacing: 2) { Text(workflow.name); Text(workflow.summary).font(.caption).foregroundStyle(Theme.secondaryText).lineLimit(2) }
                    }
                }.buttonStyle(.plain)
                .listRowBackground(Color.clear)
            }
        }.listStyle(.plain).scrollContentBackground(.hidden)
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
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { delete(chat) } label: { Label("Delete", systemImage: "trash") }
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
                    VStack(alignment: .leading, spacing: 0) {
                        Text(login).font(.subheadline.weight(.medium)).lineLimit(1)
                        Text(saveStatus).font(.caption).foregroundStyle(Theme.secondaryText).lineLimit(1)
                    }
                } else {
                    Text("Not connected to GitHub")
                        .font(.subheadline)
                        .foregroundStyle(Theme.secondaryText)
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
