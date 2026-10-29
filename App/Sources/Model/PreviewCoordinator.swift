import AgentCore
import Foundation
import Observation

@MainActor
@Observable
final class PreviewCoordinator {
    private(set) var project: WebPreviewProject?
    private(set) var directory: URL?
    private(set) var isLoading = false
    private(set) var error: String?
    private(set) var console: [String] = []
    private(set) var buildProject: WebPreviewProject?
    private(set) var resolvedCommit: String?
    @ObservationIgnored weak var app: AppModel?
    @ObservationIgnored private let root: URL

    init(root: URL) { self.root = root }

    func refresh(_ repo: ChatRepo) async {
        guard let github = app?.github.client else { error = "Connect GitHub first."; return }
        isLoading = true; error = nil; console = []
        defer { isLoading = false }
        do {
            let commit = try await github.resolveCommit(repo.ref, ref: repo.branch)
            resolvedCommit = commit
            let workspace = RepoWorkspace(repo: repo.ref, branch: repo.branch, commit: commit, github: github, store: app!.snapshots)
            let entries = try await workspace.tree().entries
            let packageData = try? await github.fileContents(repo.ref, path: "package.json", ref: commit)
            guard let detected = WebProjectDetector.detect(paths: entries.map(\.path), packageJSON: packageData) else { throw WebPreviewError.noWebEntryPoint }
            let destination = root.appendingPathComponent("\(repo.ref.owner)-\(repo.ref.name)-\(commit.prefix(12))", isDirectory: true)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            if detected.buildCommand != nil {
                buildProject = detected
                guard let app,
                      let job = app.jobs.jobs.first(where: { $0.targetRepo == repo.ref && $0.state["previewCommit"]?.stringValue == commit && $0.status == .done }),
                      let runID = job.workflowRunID else { throw WebPreviewError.buildRequired(command: detected.buildCommand!) }
                let run = try await github.workflowRun(repo.ref, runID: runID)
                guard run.conclusion == "success", run.headSHA == commit else { throw WebPreviewError.buildRequired(command: detected.buildCommand!) }
                let expectedName = "preview-site-\(job.id.uuidString.lowercased())"
                guard let artifact = try await github.artifacts(repo.ref, runID: run.id).first(where: { $0.name == expectedName && !$0.expired }) else {
                    throw WebPreviewError.missingResource(expectedName)
                }
                try PreviewArtifactExtractor.extract(try await github.artifactArchive(repo.ref, artifactID: artifact.id), to: destination)
                let paths = Self.relativeFiles(destination)
                guard let built = WebProjectDetector.detect(paths: paths), built.kind != .buildArtifact || paths.contains(built.entryPath) else { throw WebPreviewError.missingResource("index.html in the preview artifact") }
                project = built
            } else {
                buildProject = nil
                let prefix = detected.rootPath.isEmpty ? "" : detected.rootPath + "/"
                for entry in entries where entry.isFile && entry.path.hasPrefix(prefix) {
                    let relative = String(entry.path.dropFirst(prefix.count))
                    guard SnapshotStore.isSafeRelativePath(relative) else { continue }
                    let data = try await github.fileContents(repo.ref, path: entry.path, ref: commit)
                    let url = destination.appendingPathComponent(relative)
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try data.write(to: url, options: .atomic)
                }
                project = WebPreviewProject(kind: detected.kind, entryPath: detected.entryPath.split(separator: "/").last.map(String.init) ?? "index.html", rootPath: "")
            }
            directory = destination
        } catch { self.error = String(describing: error); project = nil; directory = nil }
    }

    func build(_ repo: ChatRepo) async -> Bool {
        guard let app, let project = buildProject, let commit = resolvedCommit else { return false }
        return await app.jobs.startPreviewBuild(repo: repo, project: project, commit: commit) != nil
    }

    func recordConsole(_ message: String) { if !message.isEmpty { console.append(String(message.prefix(1_000))); if console.count > 100 { console.removeFirst() } } }

    private static func relativeFiles(_ root: URL) -> [String] {
        guard let values = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        return values.compactMap { ($0 as? URL).map { String($0.path.dropFirst(root.path.count + 1)) } }
    }

    func previewError() { directory = nil; project = nil; error = "The built preview artifact did not contain an index.html file." }

    func previewFixture() {
        directory = Bundle.main.resourceURL
        project = WebPreviewProject(kind: .staticSite, entryPath: "PreviewFixture.html")
    }
}
