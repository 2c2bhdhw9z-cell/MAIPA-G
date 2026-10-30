import AgentCore
import SwiftUI

struct RecentlyDeletedScreen: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    /// Pushed inside Settings: no stack of its own and no Done button (Back returns to Settings).
    var embedded = false
    @State private var entries: [TrashEntry] = []
    @State private var error: String?
    @State private var deleting: TrashEntry?

    var body: some View {
        OwnNavigationStack(embedded: embedded) {
            Group {
                if entries.isEmpty {
                    ContentUnavailableView("Nothing recently deleted", systemImage: "trash")
                } else {
                    List(entries) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.title).font(.body.weight(.medium))
                            Text("\(entry.kind.label) · Deletes in \(daysLeft(entry)) day\(daysLeft(entry) == 1 ? "" : "s")")
                                .font(.caption)
                                .foregroundStyle(Theme.secondaryText)
                            HStack {
                                Button("Restore") { Task { await restore(entry) } }
                                    .buttonStyle(.borderedProminent)
                                Button("Delete now", role: .destructive) { deleting = entry }
                                    .buttonStyle(.bordered)
                            }
                            .font(.caption.weight(.semibold))
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .navigationTitle("Recently Deleted")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !embedded {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                }
            }
            .task { await reload() }
            .confirmationDialog("Delete forever?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
                Button("Delete forever", role: .destructive) {
                    guard let entry = deleting else { return }
                    deleting = nil
                    Task { await deleteForever(entry) }
                }
                Button("Cancel", role: .cancel) { deleting = nil }
            } message: {
                Text("This cannot be undone.")
            }
            .alert("Recently Deleted", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK") {}
            } message: {
                Text(error ?? "")
            }
        }
    }

    private func reload() async {
        _ = try? await app.trash.purgeExpired()
        entries = await app.trash.list()
    }

    private func restore(_ entry: TrashEntry) async {
        do {
            try await app.trash.restore(entry)
            await refreshLibraries()
            app.sync.request()
            await reload()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func deleteForever(_ entry: TrashEntry) async {
        do {
            try await app.trash.deleteForever(entry)
            app.sync.request()
            await reload()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func refreshLibraries() async {
        await app.library.reloadFromDisk()
        await app.memories.load()
        await app.automations.load()
    }

    private func daysLeft(_ entry: TrashEntry) -> Int {
        max(0, Calendar.current.dateComponents([.day], from: Date(), to: entry.expiresAt).day ?? 0)
    }
}
