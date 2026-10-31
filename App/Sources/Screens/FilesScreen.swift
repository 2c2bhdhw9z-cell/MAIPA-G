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
    @State private var showingPreview = false
    @State private var state: RequestState = .loading

    private enum RequestState: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    var body: some View {
        NavigationStack {
            Group {
                if let selectedPath {
                    file(path: selectedPath)
                } else {
                    browser
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
                        } label: {
                            Image(systemName: "text.badge.plus")
                        }
                        .accessibilityLabel("Add file to chat")
                    }
                    Button { showingPreview = true } label: { Image(systemName: "safari") }
                        .accessibilityLabel("Live preview")
                }
                ToolbarItem(placement: .cancellationAction) {
                    if selectedPath != nil {
                        Button {
                            selectedPath = nil; text = nil; image = nil
                        } label: {
                            Label(folder.isEmpty ? "Files" : (folder.split(separator: "/").last.map(String.init) ?? "Back"), systemImage: "chevron.left")
                        }
                    } else if !folder.isEmpty {
                        Button {
                            folder = parent(folder)
                        } label: {
                            Label("Back", systemImage: "chevron.left")
                        }
                    } else {
                        Button("Done") { dismiss() }
                    }
                }
            }
            .sheet(isPresented: $showingPreview) {
                WebPreviewScreen(repo: repo)
            }
            .task { await load() }
        }
    }

    @ViewBuilder
    private var browser: some View {
        switch state {
        case .loading:
            ProgressView("Opening repo…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn’t open repo", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Retry") { Task { await load() } }
                    .buttonStyle(.borderedProminent)
            }
        case .loaded:
            loadedBrowser
        }
    }

    @ViewBuilder
    private var loadedBrowser: some View {
        if entries.isEmpty {
            ContentUnavailableView {
                Label("This repo is empty", systemImage: "folder")
            } description: {
                Text("There are no files on \(repo.branch).")
            }
        } else {
            Group {
                if isSearching, visibleEntries.isEmpty {
                    ContentUnavailableView.search(text: normalizedQuery)
                } else {
                    List {
                        if !folder.isEmpty, !isSearching {
                            Button { folder = parent(folder) } label: {
                                Label("..", systemImage: "arrow.turn.up.left")
                            }
                        }
                        ForEach(visibleEntries, id: \.path) { entry in
                            Button { open(entry) } label: {
                                HStack {
                                    Image(systemName: entry.isFolder ? "folder" : imagePath(entry.path) ? "photo" : "doc.text")
                                    Text(entry.path.split(separator: "/").last.map(String.init) ?? entry.path)
                                    Spacer()
                                    if entry.isFolder {
                                        Image(systemName: "chevron.right")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .searchable(text: $query, prompt: "Search files")
        }
    }

    private var normalizedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isSearching: Bool { !normalizedQuery.isEmpty }

    private var visibleEntries: [GitTreeEntry] {
        if isSearching {
            return Array(entries.filter { $0.isFile && $0.path.localizedCaseInsensitiveContains(normalizedQuery) }.prefix(300))
        }
        let prefix = folder.isEmpty ? "" : folder + "/"
        return entries.filter { entry in
            guard entry.path.hasPrefix(prefix) else { return false }
            return !entry.path.dropFirst(prefix.count).contains("/")
        }
        .sorted { a, b in
            a.isFolder != b.isFolder ? a.isFolder : a.path.localizedStandardCompare(b.path) == .orderedAscending
        }
    }

    @ViewBuilder
    private func file(path: String) -> some View {
        if let image {
            ScrollView { Image(uiImage: image).resizable().scaledToFit().padding() }
        } else if let text {
            ScrollView([.horizontal, .vertical]) {
                Text(text)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            ProgressView("Opening file…").task { await loadFile(path) }
        }
    }

    private func open(_ entry: GitTreeEntry) {
        if entry.isFolder {
            folder = entry.path
            query = ""
        } else {
            selectedPath = entry.path
            text = nil
            image = nil
        }
    }

    private func load() async {
        state = .loading
        workspace = nil
        entries = []
        guard let github = app.github.client else {
            state = .failed("Connect GitHub first.")
            return
        }
        do {
            let commit = try await github.resolveCommit(repo.ref, ref: repo.branch)
            try Task.checkCancellation()
            let copy = RepoWorkspace(repo: repo.ref, branch: repo.branch, commit: commit, github: github, store: app.snapshots)
            let loadedEntries = try await copy.tree().entries
            try Task.checkCancellation()
            workspace = copy
            entries = loadedEntries
            state = .loaded
        } catch is CancellationError {
            return
        } catch {
            state = .failed(app.github.describe(error))
        }
    }

    private func loadFile(_ path: String) async {
        guard let workspace else { return }
        do {
            switch try await workspace.readFile(path) {
            case .text(let value, _): text = value
            case .binary where imagePath(path):
                if let github = app.github.client,
                   let decoded = ImageDownsampler.image(from: try await github.fileContents(repo.ref, path: path, ref: workspace.commit), maxPixelSize: 2_048) {
                    image = decoded
                } else {
                    text = "This picture can’t be read."
                }
            case .binary: text = "This file isn’t text."
            case .tooLarge: text = "This file is too large to show."
            case .symlink(let target): text = "Link to \(target)"
            case .folder: selectedPath = nil
            case .missing: text = "This file is no longer here."
            }
        } catch {
            text = "Couldn’t open this file: \(app.github.describe(error))"
        }
    }

    private func imagePath(_ path: String) -> Bool {
        ["png", "jpg", "jpeg", "gif", "webp"].contains(path.split(separator: ".").last?.lowercased() ?? "")
    }

    private func parent(_ path: String) -> String {
        path.split(separator: "/").dropLast().joined(separator: "/")
    }
}
