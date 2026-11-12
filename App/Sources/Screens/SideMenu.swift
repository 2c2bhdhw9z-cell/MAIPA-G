import AgentCore
import SwiftUI

/// The side menu: search, a new chat, every chat grouped by when it was used, and Settings.
struct SideMenu: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @State private var query = ""
    @State private var selected: ChatSummary?
    @State private var showRename = false
    @State private var showDelete = false
    @State private var newTitle = ""
    @AccessibilityFocusState(for: .voiceOver) private var newChatFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
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
        HStack(spacing: 8) {
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

    private var search: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(Theme.secondaryText)
            TextField("Search chats", text: $query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Theme.secondaryText)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Theme.sunken, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    /// Only the chats. Owner, 10 November 2026: the Chats/Specs/Agents/Workflows/Jobs tabs are gone
    /// for good, and no switch brings them back. Those screens stay reachable from the chat itself.
    private var list: some View {
        let groups = groupedChats
        return List {
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
    }

    private func row(_ chat: ChatSummary) -> some View {
        let isOpen = app.library.openSession?.id == chat.id
        // Observed on the library: the sessions themselves aren't, so this used to miss a reply
        // starting or ending in a chat whose session appeared after the list was drawn.
        let isWorking = app.library.runningChatIDs.contains(chat.id)
        return Button {
            Task {
                await app.library.open(chat.id)
                withAnimation(.snappy(duration: 0.3)) { app.isMenuOpen = false }
            }
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        if chat.isAutonomous {
                            Image(systemName: "bolt.fill")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(theme.accent)
                                .accessibilityLabel("Autonomous")
                        }
                        Text(chat.title)
                            .font(.subheadline.weight(isOpen ? .semibold : .regular))
                            .lineLimit(1)
                    }
                    Text(statusLine(chat, isWorking: isWorking))
                        .font(.caption)
                        .foregroundStyle(statusColor(chat, isWorking: isWorking))
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if isWorking || (chat.activity == .working && chat.runsOnComputer) {
                    ProgressView().controlSize(.small)
                } else if chat.activity == .needsYou {
                    Circle().fill(theme.accent).frame(width: 8, height: 8).accessibilityLabel("Needs you")
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

    /// Kiro-style status under each chat: what it's doing, or whether it needs you, finished or
    /// failed, then the repo and when.
    private func statusLine(_ chat: ChatSummary, isWorking: Bool) -> String {
        let repo = chat.repoName.map { $0.split(separator: "/").last.map(String.init) ?? $0 }
        let when = chat.updatedAt.friendlyAgo
        let state: String
        if isWorking || (chat.activity == .working && chat.runsOnComputer) {
            state = chat.activityLine.isEmpty ? "Working…" : "Working · \(chat.activityLine)"
            return state
        }
        switch chat.activity {
        case .needsYou: state = "Needs you"
        case .failed: state = "Failed"
        case .stopped, .working: state = "Stopped"
        case .done, .idle: state = ""
        }
        return [state, repo, when].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func statusColor(_ chat: ChatSummary, isWorking: Bool) -> Color {
        if isWorking || (chat.activity == .working && chat.runsOnComputer) { return theme.accent }
        switch chat.activity {
        case .needsYou: return theme.accent
        case .failed: return Theme.danger
        default: return Theme.secondaryText
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    if let login = app.github.login {
                        Image(systemName: "person.crop.circle.fill")
                            .font(.title2)
                            .foregroundStyle(theme.accent)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(login).font(.subheadline.weight(.medium)).lineLimit(1)
                            Text(saveStatus).font(.caption).foregroundStyle(Theme.secondaryText).lineLimit(1)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Not connected to GitHub")
                                .font(.subheadline)
                                .foregroundStyle(Theme.secondaryText)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 6)
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
                        app.sheet = .settings
                        app.isMenuOpen = false
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

                let badges = providerFooterBadges
                if !badges.isEmpty {
                    FlowLayout(spacing: 5, lineSpacing: 5) {
                        ForEach(badges, id: \.self) { item in
                            Text(item)
                                .font(.caption2.weight(.medium).monospacedDigit())
                                .foregroundStyle(Theme.secondaryText)
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Theme.raised.opacity(0.85), in: Capsule())
                                .overlay(Capsule().strokeBorder(Theme.stroke))
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
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

    private var providerFooterBadges: [String] {
        guard app.openRouter.isSignedIn else { return [] }
        var items: [String] = []
        let balances = app.openRouter.providerBalanceItems
        var listedNames = Set<String>()
        for entry in balances {
            items.append("\(entry.name) \(entry.balance.dollars)")
            listedNames.insert(entry.name)
        }
        for provider in app.openRouter.readyExternalProviders where !listedNames.contains(provider.name) {
            items.append(provider.name)
            listedNames.insert(provider.name)
        }
        if let free = app.openRouter.freeRequestsLeft {
            items.append("\(free) free")
        }
        return items
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
