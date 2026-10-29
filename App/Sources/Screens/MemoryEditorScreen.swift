import AgentCore
import SwiftUI

struct MemoryEditorScreen: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    var record: MemoryRecord?
    @State private var text = ""
    @State private var enabled = true
    @State private var loaded = false
    @State private var confirmDelete = false

    var body: some View {
        Form {
            Section("Memory") {
                TextField("What should MAIPA-G remember?", text: $text, axis: .vertical)
                    .lineLimit(4...12)
                Toggle("Use in new chats", isOn: $enabled)
            }
            if let record {
                Section("Details") {
                    LabeledContent("Source", value: record.source.label)
                    LabeledContent("Created", value: record.createdAt.formatted(date: .abbreviated, time: .shortened))
                    LabeledContent("Updated", value: record.updatedAt.formatted(date: .abbreviated, time: .shortened))
                }
                Section {
                    Button("Delete memory", role: .destructive) { confirmDelete = true }
                }
            }
        }
        .navigationTitle(record == nil ? "New memory" : "Edit memory")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }.disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .onAppear {
            guard !loaded else { return }
            text = record?.text ?? ""
            enabled = record?.isEnabled ?? true
            loaded = true
        }
        .confirmationDialog("Delete this memory?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let record { Task { await app.memories.delete(record.id); dismiss() } }
            }
        }
    }

    private func save() {
        var value = record ?? MemoryRecord(text: text)
        value.text = text
        value.isEnabled = enabled
        Task {
            if await app.memories.save(value) != nil { dismiss() }
        }
    }
}
