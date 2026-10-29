import AgentCore
import SwiftUI
import UIKit

struct FilesScreen: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let repo: ChatRepo
    let target: ComposerTarget
    @State private var workspace: RepoWorkspace?
    @State private var entries: [GitTreeEntry] = []
    @State private var folder = ""
    @State private var query = ""
    @State private var selectedPath: String?
    @State private var text: String?
    @State private var image: UIImage?
    @State private var message: String?

    var body: some View {
        NavigationStack {
            Group {
                if let selectedPath {
                    file(path: selectedPath)
                } else {
                    List {
                        if !folder.isEmpty {
                            Button { folder = parent(folder) } label: { Label("..", systemImage: "arrow.turn.up.left") }
                        }
                        ForEach(visibleEntries, id: \.path) { entry in
                            Button { open(entry) } label: {
                                HStack {
                                    Image(systemName: entry.isFolder ? "folder" : imagePath(entry.path) ? "photo" : "doc.text")
                                    Text(entry.path.split(separator: "/").last.map(String.init) ?? entry.path)
                                    Spacer()
                                    if entry.isFolder { Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary) }
                                }
                            }
                        }
                    }
                    .searchable(text: $query, prompt: "Search files")
                    .overlay { if entries.isEmpty && message == nil { ProgressView("Opening repo…") } }
                }
            }
            .navigationTitle(selectedPath ?? (folder.isEmpty ? repo.ref.name : folder))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    if let selectedPath, let workspace {
                        Button {
                            app.reference(repo: repo.ref, commit: workspace.commit, path: selectedPath, in: target)
                            dismiss()
                        } label: { Image(systemName: "text.badge.plus") }
                        .accessibilityLabel("Add file to chat")
                    }
                    Button { app.sheet = .webPreview(repo) } label: { Image(systemName: "safari") }
                        .accessibilityLabel("Live preview")
                }
                ToolbarItem(placement: .cancellationAction) {
                    if selectedPath != nil { Button("Files") { selectedPath = nil; text = nil; image = nil } }
                    else { Button("Done") { dismiss() } }
                }
            }
            .task { await load() }
            .alert("Couldn't open Files", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) { Button("OK") {} } message: { Text(message ?? "") }
        }
    }

    private var visibleEntries: [GitTreeEntry] {
        if !query.isEmpty { return entries.filter { $0.isFile && $0.path.localizedCaseInsensitiveContains(query) }.prefix(300).map { $0 } }
        let prefix = folder.isEmpty ? "" : folder + "/"
        return entries.filter { entry in
            guard entry.path.hasPrefix(prefix) else { return false }
            return !entry.path.dropFirst(prefix.count).contains("/")
        }.sorted { a, b in a.isFolder != b.isFolder ? a.isFolder : a.path.localizedStandardCompare(b.path) == .orderedAscending }
    }

    @ViewBuilder private func file(path: String) -> some View {
        if let image { ScrollView { Image(uiImage: image).resizable().scaledToFit().padding() } }
        else if let text { ScrollView([.horizontal, .vertical]) { Text(text).font(.system(.footnote, design: .monospaced)).textSelection(.enabled).padding().frame(maxWidth: .infinity, alignment: .leading) } }
        else { ProgressView("Opening file…").task { await loadFile(path) } }
    }

    private func open(_ entry: GitTreeEntry) {
        if entry.isFolder { folder = entry.path; query = "" }
        else { selectedPath = entry.path; text = nil; image = nil }
    }

    private func load() async {
        guard let github = app.github.client else { message = "Connect GitHub first."; return }
        do {
            let commit = try await github.resolveCommit(repo.ref, ref: repo.branch)
            let copy = RepoWorkspace(repo: repo.ref, branch: repo.branch, commit: commit, github: github, store: app.snapshots)
            workspace = copy
            entries = try await copy.tree().entries
        } catch { message = app.github.describe(error) }
    }

    private func loadFile(_ path: String) async {
        guard let workspace else { return }
        do {
            switch try await workspace.readFile(path) {
            case .text(let value, _): text = value
            case .binary where imagePath(path):
                if let github = app.github.client { image = UIImage(data: try await github.fileContents(repo.ref, path: path, ref: workspace.commit)) }
            case .binary: text = "This file isn't text."
            case .tooLarge: text = "This file is too large to show."
            case .symlink(let target): text = "Link to \(target)"
            case .folder: selectedPath = nil
            case .missing: text = "This file is no longer here."
            }
        } catch { text = "Couldn't open this file: \(error)" }
    }

    private func imagePath(_ path: String) -> Bool { ["png", "jpg", "jpeg", "gif", "webp"].contains(path.split(separator: ".").last?.lowercased() ?? "") }
    private func parent(_ path: String) -> String { path.split(separator: "/").dropLast().joined(separator: "/") }
}
