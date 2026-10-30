import Foundation

/// Mirrors MAIPA-G's saved data (chats, settings, and later memories, agents and workflows) to a
/// private repo on the user's GitHub, MAIPA-G-data, so deleting the app loses nothing.
///
/// Each sync is a three-way comparison per file between the phone's copy, GitHub's copy, and the
/// copy both agreed on last time. A file changed on one side only takes that side's version. A file
/// changed on both sides keeps whichever was updated most recently (by its `updatedAt`), and a
/// deletion never wins over an edit. Changes go up as a single commit that only lands if nobody
/// else moved the branch first; if someone did, the sync starts over with their changes included.
public actor DataRepoSync {
    public static let repoName = "MAIPA-G-data"
    static let managedJSONPrefixes = ["chats/", "memories/", "agents/", "workflows/", "groups/", "jobs/", "connectors/", "specs/", "receipts/", "drafts/", "trash/", "diagnostics/"]
    static let managedBlobPrefixes = ["attachments/", "media/"]
    static let managedFiles: Set<String> = ["settings.json"]

    public struct State: Codable, Sendable, Hashable {
        public var repo: RepoRef?
        public var branch: String?
        public var lastCommit: String?
        /// Path → Git blob id, as of `lastCommit`.
        public var files: [String: String]
        public var lastSyncAt: Date?

        public init() {
            files = [:]
        }
    }

    public struct FileProblem: Sendable, Hashable {
        public enum Stage: String, Sendable, Hashable { case read, download, write, upload }
        public var path: String
        public var stage: Stage
        public var message: String

        public init(path: String, stage: Stage, message: String) {
            self.path = path
            self.stage = stage
            self.message = message
        }
    }

    public struct Report: Sendable, Hashable {
        public var downloaded: [String] = []
        public var uploaded: [String] = []
        public var deletedHere: [String] = []
        public var deletedThere: [String] = []
        public var problems: [FileProblem] = []
        public var commit: String?

        public var changedAnything: Bool { !(downloaded.isEmpty && uploaded.isEmpty && deletedHere.isEmpty && deletedThere.isEmpty) }
    }

    public enum Failure: Error, Sendable, Equatable {
        case notSetUp
        /// The repo exists, but MAIPA-G's app isn't allowed into it.
        case repoNotVisible
    }

    private let github: GitHubClient
    private let dataDirectory: URL
    private let stateURL: URL
    public private(set) var state: State

    public init(github: GitHubClient, dataDirectory: URL, stateURL: URL) {
        self.github = github
        self.dataDirectory = dataDirectory
        self.stateURL = stateURL
        if let data = try? Data(contentsOf: stateURL), let saved = try? JSONCoding.decoder().decode(State.self, from: data) {
            state = saved
        } else {
            state = State()
        }
    }

    static func isManaged(_ path: String) -> Bool {
        guard SnapshotStore.isSafeRelativePath(path) else { return false }
        if managedFiles.contains(path) { return true }
        if path.hasSuffix(".json"), managedJSONPrefixes.contains(where: path.hasPrefix) { return true }
        return managedBlobPrefixes.contains(where: path.hasPrefix)
    }

    private func saveState() {
        try? FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONCoding.encoder(pretty: true).encode(state).write(to: stateURL, options: .atomic)
    }

    /// Finds the user's MAIPA-G-data repo, making it (private) the first time.
    /// `addToInstallation` is called with the new repo's id when the app was only let into some
    /// repos, so it can add this one.
    @discardableResult
    public func ensureRepository(owner: String, addToInstallation: (@Sendable (Int) async throws -> Void)? = nil) async throws -> RepoRef {
        let ref = RepoRef(owner: owner, name: Self.repoName)
        if let existing = try await github.repositoryIfExists(ref) {
            adopt(ref, branch: existing.defaultBranch)
            return ref
        }
        let created: GitHubRepo
        do {
            created = try await github.createUserRepository(
                name: Self.repoName,
                isPrivate: true,
                description: "MAIPA-G keeps your chats and settings here. You don't need to touch anything in it.",
                autoInit: true
            )
        } catch let error as GitHubAPIError where error.status == 422 && error.message.lowercased().contains("already exists") {
            // It exists, but the app was only let into some repos and this isn't one of them.
            throw Failure.repoNotVisible
        }
        if let addToInstallation { try? await addToInstallation(created.id) }
        // A brand-new repo can take a moment to become visible to the app.
        for attempt in 1...8 {
            if try await github.repositoryIfExists(ref) != nil { break }
            if attempt == 8 { throw Failure.repoNotVisible }
            try await Task.sleep(nanoseconds: UInt64(attempt) * 500_000_000)
        }
        adopt(ref, branch: created.defaultBranch)
        return ref
    }

    private func adopt(_ ref: RepoRef, branch: String) {
        guard state.repo != ref || state.branch != branch else { return }
        state = State()
        state.repo = ref
        state.branch = branch
        saveState()
    }

    /// Forgets which repo and files were in sync, for signing out.
    public func reset() {
        state = State()
        saveState()
    }

    /// Brings the phone and GitHub into line. Safe to call often; does nothing when nothing changed.
    @discardableResult
    public func sync() async throws -> Report {
        var attempt = 0
        while true {
            attempt += 1
            do {
                return try await syncOnce()
            } catch let error as GitHubAPIError where error.status == 422 && attempt < 4 {
                // The branch moved while we were working: someone else saved. Start over.
                continue
            }
        }
    }

    private func syncOnce() async throws -> Report {
        guard let repo = state.repo, let branch = state.branch else { throw Failure.notSetUp }
        var report = Report()
        let head = try await github.branchHead(repo, branch: branch)

        var remote: [String: String]
        if head == state.lastCommit {
            remote = state.files
        } else if let head {
            let tree = try await github.tree(repo, sha: try await github.commitTree(repo, commit: head), recursive: true)
            remote = [:]
            for entry in tree.entries where entry.isFile && Self.isManaged(entry.path) { remote[entry.path] = entry.sha }
        } else {
            remote = [:]
        }
        let scan = localFiles()
        let local = scan.files
        let base = state.files
        report.problems.append(contentsOf: scan.problems)

        var downloads: [String] = []
        var uploads: [String] = []
        var deleteHere: [String] = []
        var deleteThere: [String] = []
        var conflicts: [String] = []

        for path in Set(local.keys).union(remote.keys).union(base.keys).sorted() {
            // An unreadable local file is never interpreted as a deletion. Keep the last agreed
            // blob on GitHub and retry the local read on the next sync.
            if scan.unreadablePaths.contains(path) { continue }
            let l = local[path], r = remote[path], b = base[path]
            if l == r { continue }
            let localChanged = l != b
            let remoteChanged = r != b
            switch (localChanged, remoteChanged) {
            case (true, false):
                if l == nil { deleteThere.append(path) } else { uploads.append(path) }
            case (false, true):
                if r == nil { deleteHere.append(path) } else { downloads.append(path) }
            case (true, true):
                if l == nil { downloads.append(path) } // deleted here, edited there: keep the edit
                else if r == nil { uploads.append(path) } // edited here, deleted there: keep the edit
                else { conflicts.append(path) }
            case (false, false):
                break
            }
        }

        // Both sides edited: the newer version wins. A failure for one path is recorded and
        // leaves that path at its previous agreed blob; it cannot abort unrelated files.
        var conflictContents: [String: Data] = [:]
        var skipped = scan.unreadablePaths
        for path in conflicts {
            guard let sha = remote[path] else { continue }
            do {
                let theirs = try await github.blob(repo, sha: sha)
                let mine = try Data(contentsOf: dataDirectory.appendingPathComponent(path))
                if Self.updatedAt(theirs) ?? .distantPast > Self.updatedAt(mine) ?? .distantPast {
                    conflictContents[path] = theirs
                    downloads.append(path)
                } else {
                    uploads.append(path)
                }
            } catch {
                skipped.insert(path)
                report.problems.append(FileProblem(path: path, stage: .download, message: error.localizedDescription))
            }
        }

        // GitHub to phone. Each fetch and write is isolated. A file the phone changed while this
        // sync was running is left alone so the next sync can reconcile it.
        var fetched = conflictContents
        for path in downloads where conflictContents[path] == nil && !skipped.contains(path) {
            guard let sha = remote[path] else { continue }
            do {
                fetched[path] = try await github.blob(repo, sha: sha)
            } catch {
                skipped.insert(path)
                report.problems.append(FileProblem(path: path, stage: .download, message: error.localizedDescription))
            }
        }
        var downloadedSuccessfully: [String] = []
        for (path, data) in fetched where !skipped.contains(path) {
            let url = dataDirectory.appendingPathComponent(path)
            guard currentBlobID(at: url) == local[path] else {
                skipped.insert(path)
                continue
            }
            let safeData: Data
            if path.hasPrefix("chats/") {
                safeData = (try? SensitiveDataRedactor().redactJSON(data)) ?? data
            } else {
                safeData = data
            }
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try safeData.write(to: url, options: .atomic)
                downloadedSuccessfully.append(path)
            } catch {
                skipped.insert(path)
                report.problems.append(FileProblem(path: path, stage: .write, message: error.localizedDescription))
            }
        }
        var deletedHereSuccessfully: [String] = []
        for path in deleteHere {
            let url = dataDirectory.appendingPathComponent(path)
            guard currentBlobID(at: url) == local[path] else {
                skipped.insert(path)
                continue
            }
            do {
                if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
                deletedHereSuccessfully.append(path)
            } catch {
                skipped.insert(path)
                report.problems.append(FileProblem(path: path, stage: .write, message: error.localizedDescription))
            }
        }
        report.downloaded = downloadedSuccessfully.sorted()
        report.deletedHere = deletedHereSuccessfully.sorted()

        // What both sides now agree on. Skipped paths keep their old agreed version, so the next
        // sync still sees them as pending.
        var agreed = remote
        for path in skipped { agreed[path] = base[path] }

        // Phone to GitHub. Read/blob failures are isolated; every successful file and deletion is
        // still committed together, while failed paths remain pending for the next sync.
        var changes: [GitHubClient.TreeChange] = []
        var successfulUploads: [String] = []
        for path in uploads {
            let url = dataDirectory.appendingPathComponent(path)
            do {
                let data = try Data(contentsOf: url)
                let blob = try await github.createBlob(repo, contents: data)
                changes.append(GitHubClient.TreeChange(path: path, blobSHA: blob))
                successfulUploads.append(path)
            } catch {
                agreed[path] = base[path]
                report.problems.append(FileProblem(path: path, stage: .upload, message: error.localizedDescription))
            }
        }
        let committedDeletes = deleteThere.filter { remote[$0] != nil }
        for path in committedDeletes {
            changes.append(GitHubClient.TreeChange(path: path, blobSHA: nil))
        }

        if changes.isEmpty {
            state.files = agreed
            state.lastCommit = head
        } else {
            var baseTree: String?
            if let head { baseTree = try await github.commitTree(repo, commit: head) }
            let tree = try await github.createTree(repo, base: baseTree, changes: changes.sorted { $0.path < $1.path })
            let commit = try await github.createCommit(repo, message: Self.commitMessage(uploads: successfulUploads, deletes: committedDeletes), tree: tree, parents: head.map { [$0] } ?? [])
            if head == nil {
                _ = try await github.send("POST", GitHubClient.path(repo, "/git/refs"), body: ["ref": .string("refs/heads/\(branch)"), "sha": .string(commit)])
            } else {
                try await github.updateBranch(repo, branch: branch, to: commit)
            }
            for change in changes { agreed[change.path] = change.blobSHA }
            state.files = agreed
            state.lastCommit = commit
            report.commit = commit
        }
        report.uploaded = successfulUploads.sorted()
        report.deletedThere = changes.isEmpty ? [] : committedDeletes.sorted()
        state.lastSyncAt = Date()
        saveState()
        return report
    }

    private struct LocalScan {
        var files: [String: String] = [:]
        var unreadablePaths: Set<String> = []
        var problems: [FileProblem] = []
    }

    private func localFiles() -> LocalScan {
        var scan = LocalScan()
        let manager = FileManager.default
        guard let enumerator = manager.enumerator(
            at: dataDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return scan }
        let rootPath = dataDirectory.standardizedFileURL.path
        for case let url as URL in enumerator {
            var path = url.standardizedFileURL.path
            guard path.hasPrefix(rootPath) else { continue }
            path.removeFirst(rootPath.count)
            while path.hasPrefix("/") { path.removeFirst() }
            guard Self.isManaged(path) else { continue }
            do {
                guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
                let data = try Data(contentsOf: url)
                scan.files[path] = Hashing.gitBlobID(data)
            } catch {
                scan.unreadablePaths.insert(path)
                scan.problems.append(FileProblem(path: path, stage: .read, message: error.localizedDescription))
            }
        }
        for record in Quarantine.records(dataDirectory: dataDirectory) where scan.files[record.originalPath] == nil {
            scan.unreadablePaths.insert(record.originalPath)
            scan.problems.append(FileProblem(path: record.originalPath, stage: .read, message: "Stored file was quarantined: \(record.reason)"))
        }
        return scan
    }

    private func currentBlobID(at url: URL) -> String? {
        (try? Data(contentsOf: url)).map(Hashing.gitBlobID)
    }

    private func fetchBlobs(_ repo: RepoRef, paths: [String], ids: [String: String]) async throws -> [String: Data] {
        try await withThrowingTaskGroup(of: (String, Data).self) { group in
            var results: [String: Data] = [:]
            var pending = paths.makeIterator()
            func addNext() {
                guard let path = pending.next(), let sha = ids[path] else { return }
                group.addTask { [github] in (path, try await github.blob(repo, sha: sha)) }
            }
            for _ in 0..<6 { addNext() }
            while let (path, data) = try await group.next() {
                results[path] = data
                addNext()
            }
            return results
        }
    }

    /// Paths whose phone bytes do not match the last GitHub commit acknowledged by this device.
    /// This is local-only, so the update warning can run even while offline.
    public func pendingPaths() -> [String] {
        let scan = localFiles()
        let paths = Set(scan.files.keys).union(state.files.keys).union(scan.unreadablePaths)
        return paths.filter { path in
            scan.unreadablePaths.contains(path) || scan.files[path] != state.files[path]
        }.sorted()
    }

    static func updatedAt(_ data: Data) -> Date? {
        JSONValue.parse(data)?["updatedAt"]?.stringValue.flatMap(ISO8601.date(from:))
    }

    static func commitMessage(uploads: [String], deletes: [String]) -> String {
        let chats = uploads.filter { $0.hasPrefix("chats/") }.count
        let deletedChats = deletes.filter { $0.hasPrefix("chats/") }.count
        var parts: [String] = []
        if chats > 0 { parts.append(chats == 1 ? "1 chat" : "\(chats) chats") }
        if uploads.contains("settings.json") { parts.append("settings") }
        let others = uploads.count - chats - (uploads.contains("settings.json") ? 1 : 0)
        if others > 0 { parts.append(others == 1 ? "1 other file" : "\(others) other files") }
        var message = parts.isEmpty ? "" : "Save " + parts.joined(separator: " and ")
        if deletedChats > 0 {
            let deleted = "remove " + (deletedChats == 1 ? "1 chat" : "\(deletedChats) chats")
            message = message.isEmpty ? deleted.prefix(1).uppercased() + deleted.dropFirst() : message + ", " + deleted
        }
        return message.isEmpty ? "Update saved data" : message
    }
}

