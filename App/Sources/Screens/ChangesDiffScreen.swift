import SwiftUI

struct ChangesDiffScreen: View {
    @Environment(\.dismiss) private var dismiss
    let session: ChatSession
    @State private var scope = 0
    @State private var text = "Loading changes…"

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Changes", selection: $scope) {
                    Text("This turn").tag(0)
                    Text("Whole branch").tag(1)
                }
                .pickerStyle(.segmented)
                .padding()
                ScrollView([.horizontal, .vertical]) {
                    Text(text)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
            }
            .navigationTitle("Changes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task(id: scope) {
                text = "Loading changes…"
                text = scope == 0 ? await session.stagedDiff() : await session.branchDiff()
            }
        }
    }
}
