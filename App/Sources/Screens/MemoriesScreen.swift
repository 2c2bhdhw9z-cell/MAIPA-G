import AgentCore
import SwiftUI

struct MemoriesScreen: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    /// Pushed inside Settings: no stack of its own and no Done button (Back returns to Settings).
    var embedded = false
    @State private var query = ""
    @State private var deleting: MemoryRecord?

    var body: some View {
        OwnNavigationStack(embedded: embedded) {
            List {
                Section {
                    Toggle("Use memories in new chats", isOn: Binding(
                        get: { app.settings.memoriesOn },
                        set: { value in app.updateSettings { $0.memoriesOn = value } }
                    ))
                } footer: {
                    Text("Only memories that are on are added when a new chat starts.")
                }
                if filtered.isEmpty {
                    ContentUnavailableView(query.isEmpty ? "No memories yet" : "No memories match", systemImage: "brain", description: Text(query.isEmpty ? "Add one here, star a message, or let the AI save a useful preference." : "Try another search."))
                }
                ForEach(filtered) { memory in
                    NavigationLink { MemoryEditorScreen(record: memory) } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(memory.text).lineLimit(3)
                            HStack {
                                Label(memory.source.label, systemImage: memory.source.icon)
                                Text("·")
                                Text(memory.updatedAt.formatted(date: .abbreviated, time: .omitted))
                            }
                            .font(.caption)
                            .foregroundStyle(Theme.secondaryText)
                        }
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) { deleting = memory } label: { Label("Delete", systemImage: "trash") }
                            .tint(Theme.danger)
                        Button { Task { await app.memories.setEnabled(memory.id, !memory.isEnabled) } } label: {
                            Label(memory.isEnabled ? "Turn off" : "Turn on", systemImage: memory.isEnabled ? "pause" : "play")
                        }
                        .tint(.gray)
                    }
                }
            }
            .searchable(text: $query, prompt: "Search memories")
            .navigationTitle("Memories")
            .toolbar {
                if !embedded {
                    ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                }
                ToolbarItem(placement: .primaryAction) { NavigationLink { MemoryEditorScreen() } label: { Image(systemName: "plus") } }
            }
            .task { await app.memories.load() }
            .alert("Delete this memory?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
                Button("Delete", role: .destructive) {
                    if let deleting { Task { await app.memories.delete(deleting.id) } }
                    deleting = nil
                }
                Button("Cancel", role: .cancel) { deleting = nil }
            } message: { Text("It will be removed from this phone and MAIPA-G-data.") }
        }
    }

    private var filtered: [MemoryRecord] {
        let values = app.memories.memories
        guard !query.isEmpty else { return values }
        return values.filter { $0.text.localizedCaseInsensitiveContains(query) || $0.source.label.localizedCaseInsensitiveContains(query) }
    }
}

extension MemoryRecord.Source {
    var label: String {
        switch self { case .star: return "Starred"; case .ai: return "Saved by AI"; case .user: return "Added by you" }
    }
    var icon: String {
        switch self { case .star: return "star.fill"; case .ai: return "sparkles"; case .user: return "person" }
    }
}
