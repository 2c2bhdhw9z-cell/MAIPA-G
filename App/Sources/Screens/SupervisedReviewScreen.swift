import AgentCore
import SwiftUI

/// Kiro's Supervised review (https://kiro.dev/docs/ide/chat/autopilot/): every staged change is
/// accepted or rejected before it's saved, hunk by hunk. A rejected hunk goes back to how the repo
/// has it; accepting a file keeps what's left of it. Once everything is reviewed, "Save now" asks
/// the AI to save the accepted changes the usual way (pull request or direct save by the repo's rules).
struct SupervisedReviewScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    let session: ChatSession
    @State private var files: [ReviewFile] = []
    @State private var loading = true
    @State private var acceptedHunks: Set<String> = []

    var body: some View {
        NavigationStack {
            Group {
                if loading {
                    ProgressView("Loading changes…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if files.isEmpty {
                    ContentUnavailableView("Nothing to review", systemImage: "checkmark.circle", description: Text("There are no staged changes."))
                } else {
                    List {
                        ForEach(files) { file in
                            Section {
                                if file.isText && !file.hunks.isEmpty {
                                    ForEach(file.hunks) { hunk in
                                        hunkRow(file: file, hunk: hunk)
                                    }
                                } else {
                                    Text(file.isText ? "No line changes." : "Not a text file, so it's reviewed as a whole.")
                                        .font(.caption)
                                        .foregroundStyle(Theme.secondaryText)
                                }
                            } header: {
                                fileHeader(file)
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Review changes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if files.contains(where: { !$0.isAccepted }) {
                        Button("Accept all") {
                            Task {
                                await session.acceptAllReview()
                                await reload()
                            }
                        }
                    } else if !files.isEmpty {
                        Button("Save now") {
                            dismiss()
                            session.send("I reviewed and accepted the staged changes. Please save them.")
                        }
                        .disabled(session.isRunning)
                    }
                }
            }
            .task { await reload() }
        }
    }

    private func fileHeader(_ file: ReviewFile) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(file.path)
                    .font(.footnote.weight(.semibold))
                    .textCase(nil)
                    .lineLimit(2)
                Text(file.isAccepted ? "\(file.status.rawValue) · Accepted" : file.status.rawValue)
                    .font(.caption2)
                    .textCase(nil)
                    .foregroundStyle(file.isAccepted ? Color.green : Theme.secondaryText)
            }
            Spacer(minLength: 4)
            if !file.isAccepted {
                Button("Reject") {
                    Task {
                        await session.rejectReviewFile(file.path)
                        await reload()
                    }
                }
                .buttonStyle(.bordered)
                .tint(.red)
                Button("Accept") {
                    Task {
                        await session.acceptReviewFile(file.path)
                        await reload()
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .font(.caption.weight(.semibold))
    }

    private func hunkRow(file: ReviewFile, hunk: ReviewHunk) -> some View {
        let key = file.path + "#" + hunk.patch
        let isAccepted = file.isAccepted || acceptedHunks.contains(key)
        return VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal) {
                Text(hunk.patch)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !isAccepted {
                HStack(spacing: 10) {
                    Spacer()
                    Button("Reject") {
                        Task {
                            await session.rejectReviewHunk(path: file.path, hunk: hunk)
                            await reload()
                        }
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                    Button("Accept") {
                        acceptedHunks.insert(key)
                        // Every hunk of the file accepted: the file is accepted.
                        if file.hunks.allSatisfy({ acceptedHunks.contains(file.path + "#" + $0.patch) }) {
                            Task {
                                await session.acceptReviewFile(file.path)
                                await reload()
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .font(.caption.weight(.semibold))
            } else {
                Label("Accepted", systemImage: "checkmark")
                    .font(.caption2)
                    .foregroundStyle(.green)
            }
        }
        .padding(.vertical, 4)
    }

    private func reload() async {
        files = await session.reviewFiles()
        loading = false
    }
}
