import AgentCore
import SwiftUI

struct GroupPicker: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let target: ComposerTarget
    @State private var name = ""
    @State private var editing: ChatGroupRecord?
    @State private var deleting: ChatGroupRecord?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        choose(nil)
                    } label: {
                        HStack { Label("No group", systemImage: "tray"); Spacer(); if current == nil { Image(systemName: "checkmark") } }
                    }
                    ForEach(app.groups.groups) { group in
                        Button { choose(group.id) } label: {
                            HStack {
                                Label(group.name, systemImage: "folder")
                                Spacer()
                                if current == group.id { Image(systemName: "checkmark") }
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) { deleting = group } label: { Label("Delete", systemImage: "trash") }
                                .tint(Theme.danger)
                            Button { editing = group; name = group.name } label: { Label("Rename", systemImage: "pencil") }.tint(.gray)
                        }
                    }
                    .onMove { from, to in Task { await app.groups.move(from: from, to: to) } }
                } header: { Text("Add this chat to") }
                Section("New group") {
                    HStack {
                        TextField("Group name", text: $name)
                        Button("Add") {
                            Task {
                                if let group = await app.groups.create(name) { name = ""; choose(group.id) }
                            }
                        }
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .navigationTitle("Groups")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) { EditButton() }
            }
            .alert("Rename group", isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
                TextField("Name", text: $name)
                Button("Save") {
                    if var group = editing { group.name = name; Task { _ = await app.groups.save(group) } }
                    editing = nil; name = ""
                }
                Button("Cancel", role: .cancel) { editing = nil; name = "" }
            }
            .alert("Delete this group?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
                Button("Delete group", role: .destructive) {
                    if let deleting { Task { await app.groups.delete(deleting.id) } }
                    deleting = nil
                }
                Button("Cancel", role: .cancel) { deleting = nil }
            } message: { Text("The chats stay in Chats. Only the group is removed.") }
        }
    }

    private var current: UUID? { app.group(for: target) }

    private func choose(_ id: UUID?) {
        app.choose(group: id, for: target)
        dismiss()
    }
}
