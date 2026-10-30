import AgentCore
import SwiftUI

struct UnreadableFilesScreen: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var records: [QuarantineRecord] = []
    @State private var deleting: QuarantineRecord?
    @State private var message: String?

    var body: some View {
        NavigationStack {
            Group {
                if records.isEmpty {
                    ContentUnavailableView("No unreadable files", systemImage: "checkmark.circle")
                } else {
                    List(records, id: \.quarantinedPath) { record in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(record.originalPath).font(.footnote.monospaced()).lineLimit(2)
                            Text(record.reason).font(.caption).foregroundStyle(Theme.secondaryText).lineLimit(3)
                            Text(ByteCountFormatter.string(fromByteCount: Int64(record.bytes), countStyle: .file))
                                .font(.caption2).foregroundStyle(Theme.secondaryText)
                            HStack {
                                Button("Try again") { retry(record) }.buttonStyle(.borderedProminent)
                                ShareLink(item: Quarantine.quarantinedFile(for: record, dataDirectory: app.paths.data)) {
                                    Text("Export")
                                }
                                .buttonStyle(.bordered)
                                Button("Delete", role: .destructive) { deleting = record }.buttonStyle(.bordered)
                            }
                            .font(.caption.weight(.semibold))
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .navigationTitle("Unreadable Files")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { reload() }
            .confirmationDialog("Delete this unreadable file?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    guard let record = deleting else { return }
                    deleting = nil
                    do {
                        try Quarantine.discard(record, dataDirectory: app.paths.data)
                        app.sync.request()
                        reload()
                    } catch { message = ErrorExplainer.explain(error).message }
                }
                Button("Cancel", role: .cancel) { deleting = nil }
            } message: {
                Text("Export it first if you may need its original bytes.")
            }
            .alert("Unreadable file", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("OK") {}
            } message: { Text(message ?? "") }
        }
    }

    private func reload() {
        records = Quarantine.records(dataDirectory: app.paths.data).sorted { $0.quarantinedAt > $1.quarantinedAt }
    }

    private func retry(_ record: QuarantineRecord) {
        do {
            try Quarantine.retry(record, dataDirectory: app.paths.data)
            Task {
                await app.library.reloadFromDisk()
                await app.memories.load()
                await app.automations.load()
                await app.jobs.refresh()
                app.sync.request()
                reload()
            }
        } catch { message = ErrorExplainer.explain(error).message }
    }
}
