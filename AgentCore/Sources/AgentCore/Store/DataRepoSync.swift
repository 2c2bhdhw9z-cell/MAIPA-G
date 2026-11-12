import Foundation

/// Mirrors MAIPA-G's saved data (chats, settings, and later memories, agents and workflows) to a
/// private repo on the user's GitHub, MAIPA-G-data, so deleting the app loses nothing.
///
/// Each sync is a three-way comparison per file between the phone's copy, GitHub's copy, and the
/// copy both agreed on last time. A file changed on one side only takes that side's version. A file
/// changed on both sides keeps whichever was updated most recently (by its `updatedAt`), and a
/// deletion never wins over an edit. Changes go up in commits that only land if nobody else moved
/// the branch first; if someone did, the sync starts over with their changes included. A big pass
/// commits in pieces, so one that is stopped part way keeps everything it had already sent.
public actor DataRepoSync {
    public static let repoName = "MAIPA-G-data"
    static let managedJSONPrefixes = ["chats/", "memories/", "agents/", "workflows/", "groups/", "jobs/", "connectors/", "specs/", "receipts/", "drafts/", "trash/", "diagnostics/", "autonomous-installations/"]
    static let managedBlobPrefixes = ["attachments/", "media/"]
    static let managedFiles: Set<String> = ["settings.json"]

    public struct State: Codable, Sendable, Hashable {
        public var repo: RepoRef?
        public var branch: String?
        /// The commit `files` describes. Nil when GitHub's last listing couldn't be read in full,
        /// so the next sync lists it again instead of trusting it.
        public var lastCommit: String?
        /// The tree of `lastCommit`, so the next save builds on it without asking GitHub for it.
        public var lastTree: String?
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
        /// The last commit this pass made (a big pass commits in pieces).
        public var commit: String?
        /// How many commits this pass made.
        public var commitCount = 0
        /// Files left for the next pass because this one reached its size, count or time budget,
        /// or GitHub asked for a pause. Nothing here is lost or counted as deleted.
        public var deferred: [String] = []
        /// Paths whose phone copy still differs from GitHub's after this pass, worked out from the
        /// files this pass already read (what `pendingPaths()` says, without reading them again).
        public var pendingPaths: [String] = []
        /// GitHub asked MAIPA-G to wait (a rate limit). The pass stopped early, kept what it had
        /// saved, and the rest waits until this time.
        public var rateLimitedUntil: Date?
        /// GitHub's list of saved files couldn't be read in full even folder by folder, so this
        /// pass deleted nothing on either side.
        public var remoteListingIncomplete = false

        /// Another pass should follow straight away. Not while GitHub has asked for a pause.
        public var hasMoreToSave: Bool { !deferred.isEmpty && rateLimitedUntil == nil }

        public var changedAnything: Bool { !(downloaded.isEmpty && uploaded.isEmpty && deletedHere.isEmpty && deletedThere.isEmpty) }
    }

    public enum Failure: Error, Sendable, Equatable {
        case notSetUp
        /// The repo exists, but MAIPA-G's app isn't allowed into it.
        case repoNotVisible
    }

    private struct CachedBlobHash: Codable, Sendable, Hashable {
        var size: Int
        var modified: Double
        var blobID: String
    }

    private var github: GitHubClient
    private let dataDirectory: URL
    private let stateURL: URL
    public private(set) var state: State
    /// Attachments and media at least this big are too large to go through Git. They are stored
    /// whole, by SHA-256, as assets of MAIPA-G-data's private "MAIPA-G files" draft release, and
    /// Git keeps a small pointer next to where the file would be. Release assets hold up to 2 GB.
    public let largeFileThreshold: Int
    public static let defaultLargeFileThreshold = 20 * 1024 * 1024
    public static let pointerSuffix = ".maipa-g-file.json"
    private var largeHashes: [String: (size: Int, modified: Date, sha256: String)] = [:]
    private var blobHashes: [String: CachedBlobHash] = [:]
    /// Set when `blobHashes` changed since it was last written, so an unchanged cache isn't
    /// rewritten on every pass.
    private var hashCacheDirty = false
    /// Blobs GitHub accepted that no commit holds yet (the pass stopped before committing them),
    /// with when they were sent. The next pass uses them as they are instead of sending the same
    /// bytes again. Kept on disk next to the sync state, and only for a day.
    private var uploadedBlobs: [String: Date] = [:]
    static let uploadedBlobLifetime: TimeInterval = 24 * 60 * 60
    /// Pictures and other big attachments at least this size are not read again when this phone
    /// already agreed on their id. Reading all of them on open is what was closing the app.
    private static let rememberedFileBytes = 1024 * 1024
    /// How many bytes of brand-new big files one scan may read to work out their ids. The rest
    /// wait for the next pass, so a big import never means reading every file at once.
    var newFileReadBudget = 48 * 1024 * 1024

    /// One pass uploads at most this much and then commits it, so a backlog is saved in pieces;
    /// the next pass starts as soon as this one is committed and nothing is skipped for good.
    /// 50 files at GitHub's one write a second fits well inside a pass.
    var uploadFileLimit = 50
    var uploadByteLimit = 40 * 1024 * 1024
    var uploadTimeLimit: TimeInterval = 75
    /// Files sent side by side. Each still waits its turn at the write pacer, so they start a
    /// second apart and only the sending overlaps.
    var uploadParallelism = 4
    /// What one group of side-by-side uploads may hold in memory; a bigger file goes alone.
    var uploadGroupBytes = 16 * 1024 * 1024
    /// Uploads are committed every this many files or seconds, whichever comes first, so a pass
    /// that is stopped keeps what it sent.
    var commitEveryFiles = 25
    var commitEverySeconds: TimeInterval = 20
    /// A chat whose reply is still streaming is left until the reply ends, then saved once. One
    /// that streams for longer than this is saved anyway, and then left again for as long.
    var holdLimit: TimeInterval = 10 * 60
    private var heldSince: [String: TimeInterval] = [:]
    /// Most tree listings one pass makes when GitHub's single listing comes back cut short.
    var treeListingBudget = 400
    /// GitHub asks for at least a second between requests that write.
    public static let defaultWriteSpacing: TimeInterval = 1

    /// Touched by every answer from GitHub and as a body is sent, so whoever is waiting can tell
    /// a slow but moving save from a stuck one.
    public nonisolated let activity: ActivityClock
    /// How far the running pass has got, and a way to ask it to finish early.
    public nonisolated let monitor = SyncPassMonitor()
    private var running: Task<Void, Never>?

    /// For tests: smaller passes.
    func setPassLimits(
        files: Int? = nil, bytes: Int? = nil, seconds: TimeInterval? = nil, newFileReadBytes: Int? = nil,
        parallel: Int? = nil, commitEvery: Int? = nil, commitSeconds: TimeInterval? = nil,
        holdSeconds: TimeInterval? = nil, treeRequests: Int? = nil, writeSpacing: TimeInterval? = nil
    ) {
        if let files { uploadFileLimit = files }
        if let bytes { uploadByteLimit = bytes }
        if let seconds { uploadTimeLimit = seconds }
        if let newFileReadBytes { newFileReadBudget = newFileReadBytes }
        if let parallel { uploadParallelism = max(parallel, 1) }
        if let commitEvery { commitEveryFiles = max(commitEvery, 1) }
        if let commitSeconds { commitEverySeconds = commitSeconds }
        if let holdSeconds { holdLimit = holdSeconds }
        if let treeRequests { treeListingBudget = treeRequests }
        if let writeSpacing { github.writePacer = WritePacer(spacing: writeSpacing) }
    }

    public init(
        github: GitHubClient,
        dataDirectory: URL,
        stateURL: URL,
        largeFileThreshold: Int = DataRepoSync.defaultLargeFileThreshold,
        writeSpacing: TimeInterval = DataRepoSync.defaultWriteSpacing
    ) {
        let clock = ActivityClock()
        var client = github
        client.activity = clock
        client.writePacer = WritePacer(spacing: writeSpacing)
        self.github = client
        self.activity = clock
        self.dataDirectory = dataDirectory
        self.stateURL = stateURL
        self.largeFileThreshold = largeFileThreshold
        if let data = try? Data(contentsOf: stateURL), let saved = try? JSONCoding.decoder().decode(State.self, from: data) {
            state = saved
        } else {
            state = State()
        }
        if let data = try? Data(contentsOf: Self.hashCacheURL(for: stateURL)),
           let saved = try? JSONCoding.decoder().decode([String: CachedBlobHash].self, from: data) {
            blobHashes = saved
        }
        if let data = try? Data(contentsOf: Self.uploadedBlobsURL(for: stateURL)),
           let saved = try? JSONCoding.decoder().decode([String: Date].self, from: data) {
            let cutoff = Date().addingTimeInterval(-Self.uploadedBlobLifetime)
            uploadedBlobs = saved.filter { $0.value > cutoff }
        }
    }

    static func isManaged(_ path: String) -> Bool {
        guard SnapshotStore.isSafeRelativePath(path) else { return false }
        if managedFiles.contains(path) { return true }
        if path.hasSuffix(".json"), managedJSONPrefixes.contains(where: path.hasPrefix) { return true }
        return managedBlobPrefixes.contains(where: path.hasPrefix)
    }

    /// True when a folder (ending in "/") may hold files MAIPA-G saves.
    static func mayHoldManaged(folder: String) -> Bool {
        (managedJSONPrefixes + managedBlobPrefixes).contains { $0.hasPrefix(folder) || folder.hasPrefix($0) }
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
        uploadedBlobs = [:]
        saveUploadedBlobs()
    }

    /// Forgets which repo and files were in sync, for signing out.
    public func reset() {
        state = State()
        blobHashes = [:]
        hashCacheDirty = false
        uploadedBlobs = [:]
        heldSince = [:]
        saveState()
        try? FileManager.default.removeItem(at: Self.hashCacheURL(for: stateURL))
        try? FileManager.default.removeItem(at: Self.uploadedBlobsURL(for: stateURL))
    }

    private nonisolated static func hashCacheURL(for stateURL: URL) -> URL {
        stateURL.deletingLastPathComponent().appendingPathComponent("blob-hash-cache.json")
    }

    nonisolated static func uploadedBlobsURL(for stateURL: URL) -> URL {
        stateURL.deletingLastPathComponent().appendingPathComponent("uploaded-blobs.json")
    }

    private func setBlobHash(_ path: String, _ value: CachedBlobHash) {
        guard blobHashes[path] != value else { return }
        blobHashes[path] = value
        hashCacheDirty = true
    }

    private func saveHashCache() {
        guard hashCacheDirty else { return }
        let url = Self.hashCacheURL(for: stateURL)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if (try? JSONCoding.encoder().encode(blobHashes).write(to: url, options: .atomic)) != nil {
            hashCacheDirty = false
        }
    }

    private func saveUploadedBlobs() {
        let url = Self.uploadedBlobsURL(for: stateURL)
        let cutoff = Date().addingTimeInterval(-Self.uploadedBlobLifetime)
        uploadedBlobs = uploadedBlobs.filter { $0.value > cutoff }
        if uploadedBlobs.isEmpty {
            try? FileManager.default.removeItem(at: url)
            return
        }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONCoding.encoder().encode(uploadedBlobs).write(to: url, options: .atomic)
    }

    /// Notes a blob GitHub accepted, before any commit holds it.
    private func noteUploaded(_ blob: String) {
        uploadedBlobs[blob] = Date()
        saveUploadedBlobs()
    }

    /// Drops journal entries a commit now holds: they are in `state.files` from here on.
    private func forgetCommittedBlobs() {
        guard !uploadedBlobs.isEmpty else { return }
        let committed = Set(state.files.values)
        let before = uploadedBlobs.count
        uploadedBlobs = uploadedBlobs.filter { !committed.contains($0.key) }
        if uploadedBlobs.count != before { saveUploadedBlobs() }
    }

    private static func isRefConflict(_ error: GitHubAPIError) -> Bool {
        if error.status == 409 { return true }
        guard error.status == 422 else { return false }
        let lower = error.message.lowercased()
        return lower.contains("fast forward") || lower.contains("fast-forward") || lower.contains("reference")
    }

    /// Brings the phone and GitHub into line. Safe to call often; does nothing when nothing changed.
    /// `holding` names files to leave alone this pass (chats whose reply is still streaming): they
    /// are neither sent, fetched nor deleted, and are saved once they are no longer held.
    @discardableResult
    public func sync(holding held: Set<String> = []) async throws -> Report {
        // A sync the app stopped waiting for (it went quiet too long) may still be winding down.
        // Two at once would each commit from the same starting point, so wait for it.
        while let previous = running { await previous.value }
        let (finished, finish) = AsyncStream<Void>.makeStream()
        let marker = Task { for await _ in finished {} }
        running = marker
        defer {
            finish.finish()
            if running == marker { running = nil }
            monitor.setFilesLeft(nil)
        }
        var attempt = 0
        while true {
            attempt += 1
            do {
                return try await syncOnce(holding: held)
            } catch let error as GitHubAPIError where Self.isRefConflict(error) && attempt < 4 {
                // The branch moved while we were working: someone else saved. Start over after brief backoff.
                try? await Task.sleep(nanoseconds: UInt64(attempt) * 120_000_000)
                continue
            }
        }
    }

    /// The paths held back this pass: asked for, and not yet held longer than `holdLimit`.
    private func holdBack(_ requested: Set<String>) -> Set<String> {
        let now = ProcessInfo.processInfo.systemUptime
        heldSince = heldSince.filter { requested.contains($0.key) }
        var held: Set<String> = []
        for path in requested {
            let since = heldSince[path] ?? now
            if now - since >= holdLimit {
                // Held long enough: saved this pass, then held again from now.
                heldSince[path] = now
            } else {
                heldSince[path] = since
                held.insert(path)
            }
        }
        return held
    }

    /// Where the next commit goes on top of: the branch's commit and its tree.
    private struct CommitCursor {
        var head: String?
        var tree: String?
    }

    /// What one pass has sent and committed so far.
    private struct PassProgress {
        var cursor: CommitCursor
        /// Sent (or already on GitHub) and waiting for the next commit.
        var pending: [GitHubClient.TreeChange] = []
        var pendingPaths: [String] = []
        var committedUploads: [String] = []
        var committedBlobs: [String: String] = [:]
        var committedDeletes: Set<String> = []
        var commits: [String] = []
        var lastCommitAt: TimeInterval
        /// GitHub asked for a pause.
        var rateLimit: GitHubAPIError?
        /// A commit was refused by a rate limit, so no more are tried this pass.
        var commitsBlocked = false

        init(cursor: CommitCursor, lastCommitAt: TimeInterval) {
            self.cursor = cursor
            self.lastCommitAt = lastCommitAt
        }

        mutating func add(_ path: String, blob: String) {
            pending.append(GitHubClient.TreeChange(path: path, blobSHA: blob))
            pendingPaths.append(path)
        }
    }

    /// Commits what the pass has waiting (and `deletes`), unless a rate limit already stopped
    /// commits. A rate limit here is noted rather than thrown: the blobs are remembered, so the
    /// next pass only has to commit them.
    private func commitPending(
        _ progress: inout PassProgress, deletes: [String] = [], repo: RepoRef, branch: String,
        agreed: inout [String: String], listingComplete: Bool
    ) async throws {
        let changes = progress.pending + deletes.map { GitHubClient.TreeChange(path: $0, blobSHA: nil) }
        guard !changes.isEmpty, !progress.commitsBlocked else { return }
        do {
            let commit = try await commitPiece(
                repo, branch: branch, cursor: &progress.cursor, changes: changes,
                uploads: progress.pendingPaths, deletes: deletes, agreed: &agreed, listingComplete: listingComplete
            )
            progress.commits.append(commit)
            progress.committedUploads += progress.pendingPaths
            for change in progress.pending { progress.committedBlobs[change.path] = change.blobSHA }
            progress.committedDeletes.formUnion(deletes)
            progress.pending = []
            progress.pendingPaths = []
            progress.lastCommitAt = ProcessInfo.processInfo.systemUptime
        } catch let error as GitHubAPIError where error.isRateLimited {
            progress.rateLimit = progress.rateLimit ?? error
            progress.commitsBlocked = true
        }
    }

    /// One file waiting to go up.
    private struct UploadJob: Sendable {
        enum Kind: Sendable {
            case blob(Data)
            /// A big file for the files release, and the pointer Git keeps for it.
            case large(LargeFile, LargeFileStore)
        }
        var path: String
        var kind: Kind
        /// The id the bytes (or the pointer) will have in Git.
        var blobID: String
        /// GitHub already has that blob, so only a big file's release copy has to be checked.
        var blobStored: Bool

        func run(_ github: GitHubClient, repo: RepoRef) async throws -> String {
            switch kind {
            case .blob(let data):
                return try await github.createBlob(repo, contents: data)
            case .large(let file, let store):
                try await store.ensure(file)
                if blobStored { return blobID }
                return try await github.createBlob(repo, contents: file.pointer)
            }
        }
    }

    /// Sends a group of files side by side and gives back each one's blob id or error, in order.
    private nonisolated static func runGroup(_ jobs: [UploadJob], github: GitHubClient, repo: RepoRef) async -> [Result<String, Error>] {
        await withTaskGroup(of: (Int, Result<String, Error>).self) { group in
            for (index, job) in jobs.enumerated() {
                group.addTask {
                    do { return (index, .success(try await job.run(github, repo: repo))) }
                    catch { return (index, .failure(error)) }
                }
            }
            var results = [Result<String, Error>?](repeating: nil, count: jobs.count)
            for await (index, result) in group { results[index] = result }
            return results.map { $0 ?? .failure(CancellationError()) }
        }
    }

    /// Commits `changes` on top of `cursor`, moves the branch there, and records it as agreed, so a
    /// pass stopped after this keeps it. The cursor moves on to the new commit.
    private func commitPiece(
        _ repo: RepoRef, branch: String, cursor: inout CommitCursor, changes: [GitHubClient.TreeChange],
        uploads: [String], deletes: [String], agreed: inout [String: String], listingComplete: Bool
    ) async throws -> String {
        var baseTree = cursor.tree
        if baseTree == nil, let head = cursor.head { baseTree = try await github.commitTree(repo, commit: head) }
        let tree: String
        do {
            tree = try await github.createTree(repo, base: baseTree, changes: changes.sorted { $0.path < $1.path })
        } catch let error as GitHubAPIError where error.status == 422 && !Self.isRefConflict(error) && !uploadedBlobs.isEmpty {
            // A blob sent by an earlier pass and never committed may be gone from GitHub by now.
            // Forget them all; the next pass sends whatever is still needed again.
            uploadedBlobs = [:]
            saveUploadedBlobs()
            throw error
        }
        let commit = try await github.createCommit(repo, message: Self.commitMessage(uploads: uploads, deletes: deletes), tree: tree, parents: cursor.head.map { [$0] } ?? [])
        if cursor.head == nil {
            try await github.createBranchRef(repo, branch: branch, at: commit)
        } else {
            try await github.updateBranch(repo, branch: branch, to: commit)
        }
        cursor = CommitCursor(head: commit, tree: tree)
        for change in changes { agreed[change.path] = change.blobSHA }
        state.files = agreed
        // A listing that wasn't complete is never trusted as a shortcut next time.
        state.lastCommit = listingComplete ? commit : nil
        state.lastTree = tree
        saveState()
        forgetCommittedBlobs()
        monitor.noteCommitted(changes.count)
        return commit
    }

    /// Every file MAIPA-G saves in `tree`. GitHub's one-call listing stops at 100,000 entries or
    /// 7 MB and then says `truncated`; as GitHub's docs advise, each folder is then listed on its
    /// own (one recursive listing per folder, and a folder still too long one level at a time).
    /// `complete` is false only when even that couldn't list everything.
    private func remoteFiles(_ repo: RepoRef, tree: String) async throws -> (files: [String: String], complete: Bool) {
        let whole = try await github.tree(repo, sha: tree, recursive: true)
        if !whole.truncated { return (Self.managedEntries(whole.entries, under: ""), true) }
        var files: [String: String] = [:]
        var complete = true
        var requests = 1
        var folders: [(sha: String, prefix: String, recursive: Bool)] = [(tree, "", false)]
        while let folder = folders.popLast() {
            guard requests < treeListingBudget else {
                complete = false
                break
            }
            requests += 1
            let listing = try await github.tree(repo, sha: folder.sha, recursive: folder.recursive)
            if folder.recursive {
                if listing.truncated {
                    folders.append((folder.sha, folder.prefix, false))
                } else {
                    files.merge(Self.managedEntries(listing.entries, under: folder.prefix)) { _, new in new }
                }
                continue
            }
            if listing.truncated { complete = false }
            for entry in listing.entries {
                let path = folder.prefix + entry.path
                if entry.isFile {
                    if Self.isManaged(path) { files[path] = entry.sha }
                } else if entry.isFolder, Self.mayHoldManaged(folder: path + "/") {
                    folders.append((entry.sha, path + "/", true))
                }
            }
        }
        return (files, complete)
    }

    private static func managedEntries(_ entries: [GitTreeEntry], under prefix: String) -> [String: String] {
        var files: [String: String] = [:]
        for entry in entries where entry.isFile {
            let path = prefix + entry.path
            if isManaged(path) { files[path] = entry.sha }
        }
        return files
    }

    /// A file's bytes as they go to GitHub. A chat is checked for secrets first, and the cleaned
    /// copy replaces the phone's.
    private func uploadBytes(_ path: String, at url: URL) throws -> Data {
        let raw = try Data(contentsOf: url)
        guard path.hasPrefix("chats/") else { return raw }
        let safe = (try? SensitiveDataRedactor().redactJSON(raw)) ?? raw
        if safe != raw {
            try? safe.write(to: url, options: .atomic)
            if let vals = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) {
                setBlobHash(path, CachedBlobHash(
                    size: vals.fileSize ?? safe.count,
                    modified: (vals.contentModificationDate ?? Date()).timeIntervalSince1970,
                    blobID: Hashing.gitBlobID(safe)
                ))
            }
        }
        return safe
    }

    private func syncOnce(holding requested: Set<String>) async throws -> Report {
        guard let repo = state.repo, let branch = state.branch else { throw Failure.notSetUp }
        var report = Report()
        activity.touch()
        let head = try await github.branchHead(repo, branch: branch)

        var remote: [String: String]
        var remoteComplete = true
        var headTree: String?
        if head == state.lastCommit {
            remote = state.files
            headTree = state.lastTree
        } else if let head {
            let tree = try await github.commitTree(repo, commit: head)
            headTree = tree
            let listing = try await remoteFiles(repo, tree: tree)
            remote = listing.files
            remoteComplete = listing.complete
        } else {
            remote = [:]
        }
        let base = state.files
        if !remoteComplete {
            // Not listed is not deleted: whatever GitHub's list didn't reach counts as unchanged
            // there, and nothing is deleted on either side until a full list is read.
            for (path, sha) in base where remote[path] == nil { remote[path] = sha }
            report.remoteListingIncomplete = true
        }
        let held = holdBack(requested)
        let scan = localFiles(remote: remote)
        let local = scan.files
        report.problems.append(contentsOf: scan.problems)

        var downloads: [String] = []
        var uploads: [String] = []
        var deleteHere: [String] = []
        var deleteThere: [String] = []
        var conflicts: [String] = []

        for path in Set(local.keys).union(remote.keys).union(base.keys).sorted() {
            // An unreadable local file is never interpreted as a deletion. Keep the last agreed
            // blob on GitHub and retry the local read on the next sync. A held one (a chat still
            // streaming) waits the same way.
            if scan.unreadablePaths.contains(path) || held.contains(path) { continue }
            // A big file the phone has, still saved in Git by an older build: its pointer takes
            // over, and the Git copy goes once the release copy is safe (checked below).
            if scan.largeRealPaths.contains(path) {
                if remote[path] != nil { deleteThere.append(path) }
                continue
            }
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
        var skipped = scan.unreadablePaths.union(held)
        if !remoteComplete {
            // Deletions wait for a complete list (see above).
            skipped.formUnion(deleteHere)
            deleteHere = []
        }
        for path in conflicts {
            guard let sha = remote[path] else { continue }
            if Self.isPointer(path) {
                uploads.append(path)
                continue
            }
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

        // GitHub to phone. Each fetch and write is isolated (up to 6 blobs fetched concurrently).
        // A file the phone changed while this sync was running is left alone so the next sync can reconcile it.
        var fetched = conflictContents
        let remainingDownloads = downloads.filter { conflictContents[$0] == nil && !skipped.contains($0) && remote[$0] != nil }
        if !remainingDownloads.isEmpty {
            let outcomes = await fetchBlobsIsolated(repo, paths: remainingDownloads, ids: remote)
            for (path, outcome) in outcomes {
                switch outcome {
                case .success(let blobData):
                    fetched[path] = blobData
                case .failure(let error):
                    skipped.insert(path)
                    report.problems.append(FileProblem(path: path, stage: .download, message: error.localizedDescription))
                }
            }
        }
        var downloadedSuccessfully: [String] = []
        var downloadStore: LargeFileStore?
        for (path, data) in fetched where !skipped.contains(path) {
            let url = dataDirectory.appendingPathComponent(path)
            if Self.isPointer(path) {
                // A big file saved from another phone: fetch it from the release and check it.
                guard currentBlobID(forPath: path) == local[path] else {
                    skipped.insert(path)
                    continue
                }
                do {
                    guard let pointer = LargeFilePointer.parse(data), pointer.path == Self.realPath(forPointer: path) else {
                        throw GitHubAPIError(status: 0, message: "The saved pointer for \(Self.realPath(forPointer: path)) can't be read")
                    }
                    if downloadStore == nil { downloadStore = try await LargeFileStore(github: github, repo: repo) }
                    // The download reports its progress to `activity` as the bytes arrive.
                    try await downloadStore?.fetch(pointer, into: dataDirectory)
                    downloadedSuccessfully.append(path)
                } catch {
                    skipped.insert(path)
                    report.problems.append(FileProblem(path: Self.realPath(forPointer: path), stage: .download, message: ErrorExplainer.describe(error).message))
                }
                continue
            }
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
            let url = Self.isPointer(path) ? dataDirectory.appendingPathComponent(Self.realPath(forPointer: path)) : dataDirectory.appendingPathComponent(path)
            guard currentBlobID(forPath: path) == local[path] else {
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
        // sync still sees them as pending. If a downloaded chat contained a secret that was redacted
        // locally, record the local redacted blob hash only after uploading or leave base so local wins cleanly.
        var agreed = remote
        for path in skipped { agreed[path] = base[path] }
        for path in downloadedSuccessfully where path.hasPrefix("chats/") {
            let localURL = dataDirectory.appendingPathComponent(path)
            if let diskBytes = try? Data(contentsOf: localURL) {
                let diskBlob = Hashing.gitBlobID(diskBytes)
                if let vals = try? localURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) {
                    setBlobHash(path, CachedBlobHash(
                        size: vals.fileSize ?? diskBytes.count,
                        modified: (vals.contentModificationDate ?? Date()).timeIntervalSince1970,
                        blobID: diskBlob
                    ))
                }
            }
        }

        // Phone to GitHub. Read/blob failures are isolated and failed paths stay pending for the
        // next sync. Files go up a few at a time and are committed in pieces (every
        // `commitEveryFiles` files or `commitEverySeconds`), so a pass that is stopped keeps what
        // it sent; blobs sent but not yet committed are remembered (`uploadedBlobs`) for the next.
        var progress = PassProgress(cursor: CommitCursor(head: head, tree: headTree), lastCommitAt: ProcessInfo.processInfo.systemUptime)
        var sentThisPass = 0
        var readyUploads: Set<String> = []
        var store: LargeFileStore?
        let passStarted = ProcessInfo.processInfo.systemUptime
        var startedUploads = 0
        var startedBytes = 0
        // Every file GitHub already has, by content. Attaching the same file again (or many
        // copies of it at once) used to upload every copy; GitHub keeps one, so the others were
        // bytes sent for nothing, and on a phone connection they made the save time out.
        var storedBlobs = Set(remote.values).union(base.values).union(uploadedBlobs.keys)
        var queue = ArraySlice(Self.uploadOrder(uploads))
        // The first file goes alone: if GitHub is refusing (a rate limit), one request finds out.
        var groupSize = 1
        monitor.setFilesLeft(queue.count)

        uploading: while !queue.isEmpty {
            try Task.checkCancellation()
            var group: [UploadJob] = []
            var groupBytes = 0
            var groupBlobs: Set<String> = []
            var stopAfterGroup = false
            while group.count < groupSize, let path = queue.first {
                let url = dataDirectory.appendingPathComponent(path)
                if !path.hasPrefix("chats/"), scan.largeFiles[path] == nil, let blob = local[path], storedBlobs.contains(blob) {
                    queue.removeFirst()
                    progress.add(path, blob: blob)
                    readyUploads.insert(path)
                    continue
                }
                // A copy of a file already in this group waits for the next, where it costs nothing.
                if let blob = local[path], groupBlobs.contains(blob) { break }
                let large = scan.largeFiles[path]
                let size = large?.size ?? ((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
                // Past this pass's budget: leave the rest for the next pass, which starts as soon as
                // this one is committed. At least one file always goes, so every pass makes progress,
                // unless the app asked this pass to finish (it is going to the background).
                // A file that would take the pass past its byte budget waits for the next one.
                let finishing = (monitor.secondsUntilFinish() ?? 1) <= 0
                let overBudget = startedUploads >= uploadFileLimit || (large == nil && startedBytes + size > uploadByteLimit)
                    || ProcessInfo.processInfo.systemUptime - passStarted >= uploadTimeLimit
                if finishing || (startedUploads > 0 && overBudget) {
                    stopAfterGroup = true
                    break
                }
                // A group holds only so much in memory at once; a big file waits to go alone.
                if !group.isEmpty, large == nil, groupBytes + size > uploadGroupBytes { break }
                queue.removeFirst()
                startedUploads += 1
                startedBytes += size
                do {
                    if let large {
                        if store == nil { store = try await LargeFileStore(github: github, repo: repo) }
                        guard let fileStore = store else { continue }
                        let pointerBlob = Hashing.gitBlobID(large.pointer)
                        group.append(UploadJob(path: path, kind: .large(large, fileStore), blobID: pointerBlob, blobStored: storedBlobs.contains(pointerBlob)))
                        groupBlobs.insert(pointerBlob)
                    } else {
                        let data = try uploadBytes(path, at: url)
                        let known = Hashing.gitBlobID(data)
                        if storedBlobs.contains(known) {
                            progress.add(path, blob: known)
                            readyUploads.insert(path)
                            continue
                        }
                        group.append(UploadJob(path: path, kind: .blob(data), blobID: known, blobStored: false))
                        groupBlobs.insert(known)
                        if let scanned = local[path] { groupBlobs.insert(scanned) }
                        groupBytes += data.count
                    }
                } catch let error as GitHubAPIError where error.isRateLimited {
                    progress.rateLimit = error
                    agreed[path] = base[path]
                    report.deferred.append(path)
                    break
                } catch where Self.isMissingFile(error) {
                    // Deleted or replaced on the phone after this sync looked at it: not a failure.
                    // The next sync sees what is there now.
                    agreed[path] = base[path]
                } catch {
                    agreed[path] = base[path]
                    report.problems.append(FileProblem(path: path, stage: .upload, message: ErrorExplainer.describe(error).message))
                }
            }
            if progress.rateLimit != nil {
                // Nothing more goes while GitHub asks for a pause, not even what was just read.
                for job in group {
                    agreed[job.path] = base[job.path]
                    report.deferred.append(job.path)
                }
                group = []
            }
            if !group.isEmpty {
                groupSize = uploadParallelism
                let outcomes = await Self.runGroup(group, github: github, repo: repo)
                for (job, outcome) in zip(group, outcomes) {
                    switch outcome {
                    case .success(let blob):
                        storedBlobs.insert(blob)
                        noteUploaded(blob)
                        sentThisPass += 1
                        progress.add(job.path, blob: blob)
                        readyUploads.insert(job.path)
                    case .failure(let error as GitHubAPIError) where error.isRateLimited:
                        // GitHub asked for a pause: stop sending, keep what went up, and leave
                        // the rest for the pass after the pause.
                        progress.rateLimit = progress.rateLimit ?? error
                        agreed[job.path] = base[job.path]
                        report.deferred.append(job.path)
                    case .failure(let error) where Self.isMissingFile(error):
                        agreed[job.path] = base[job.path]
                    case .failure(let error):
                        if error is CancellationError { throw error }
                        agreed[job.path] = base[job.path]
                        report.problems.append(FileProblem(path: job.path, stage: .upload, message: ErrorExplainer.describe(error).message))
                    }
                }
            }
            monitor.setFilesLeft(queue.count)
            if progress.rateLimit != nil || stopAfterGroup { break uploading }
            if progress.pending.count >= commitEveryFiles
                || (!progress.pending.isEmpty && ProcessInfo.processInfo.systemUptime - progress.lastCommitAt >= commitEverySeconds) {
                try await commitPending(&progress, repo: repo, branch: branch, agreed: &agreed, listingComplete: remoteComplete)
                if progress.commitsBlocked { break uploading }
            }
        }
        // Whatever didn't start this pass waits for the next.
        for path in queue {
            agreed[path] = base[path]
            report.deferred.append(path)
        }

        // A file moving from Git to the files release keeps its Git copy until the release copy
        // and its pointer are saved.
        let unsavedLargeFiles = Set(uploads.filter { Self.isPointer($0) && !readyUploads.contains($0) }.map(Self.realPath(forPointer:)))
        let deletes = remoteComplete ? deleteThere.filter { remote[$0] != nil && !unsavedLargeFiles.contains($0) } : []
        for path in deleteThere where !deletes.contains(path) { agreed[path] = base[path] }
        try await commitPending(&progress, deletes: deletes, repo: repo, branch: branch, agreed: &agreed, listingComplete: remoteComplete)
        if progress.commitsBlocked {
            // Sent but not committed: still pending, and remembered, so the next pass only commits.
            for change in progress.pending { agreed[change.path] = base[change.path] }
            for path in deletes where !progress.committedDeletes.contains(path) { agreed[path] = base[path] }
            report.deferred += progress.pendingPaths
        }
        report.deferred = Array(Set(report.deferred).union(scan.deferred)).sorted()
        report.commit = progress.commits.last
        report.commitCount = progress.commits.count
        state.files = agreed
        if progress.commits.isEmpty {
            state.lastCommit = remoteComplete ? head : nil
            state.lastTree = headTree
        } else {
            state.lastCommit = remoteComplete ? progress.cursor.head : nil
            state.lastTree = progress.cursor.tree
        }
        report.uploaded = progress.committedUploads.sorted()
        report.deletedThere = progress.committedDeletes.sorted()
        state.lastSyncAt = Date()
        saveState()
        saveHashCache()

        // What still differs, from what this pass read and did, so nobody has to read every file
        // again to find out.
        var after = local
        for path in downloadedSuccessfully {
            after[path] = path.hasPrefix("chats/") ? (blobHashes[path]?.blobID ?? remote[path]) : remote[path]
        }
        for path in deletedHereSuccessfully { after[path] = nil }
        for (path, blob) in progress.committedBlobs { after[path] = blob }
        for path in progress.committedDeletes { after[path] = nil }
        report.pendingPaths = Set(after.keys).union(state.files.keys).union(scan.unreadablePaths).filter { path in
            scan.unreadablePaths.contains(path) || after[path] != state.files[path]
        }.sorted()

        if let rateLimit = progress.rateLimit {
            report.rateLimitedUntil = rateLimit.retryAt ?? Date().addingTimeInterval(60)
            // Nothing at all got through: the pause is the whole story.
            if report.commitCount == 0, sentThisPass == 0, report.downloaded.isEmpty, report.deletedHere.isEmpty {
                throw rateLimit
            }
        }
        return report
    }

    private struct LocalScan {
        var files: [String: String] = [:]
        var unreadablePaths: Set<String> = []
        var problems: [FileProblem] = []
        /// Pointer path → the big file it stands for.
        var largeFiles: [String: LargeFile] = [:]
        /// Where those big files really are.
        var largeRealPaths: Set<String> = []
        /// New big files left unread to keep this scan's reading bounded; a later pass reads them.
        var deferred: Set<String> = []
    }

    /// Settings and chats first, then everything else, smallest kinds before pictures and files,
    /// so a pass that stops at its budget has saved what matters most.
    static func uploadOrder(_ paths: [String]) -> [String] {
        func rank(_ path: String) -> Int {
            if managedFiles.contains(path) { return 0 }
            if path.hasPrefix("chats/") { return 1 }
            if path.hasSuffix(".json"), managedJSONPrefixes.contains(where: path.hasPrefix) { return 2 }
            return 3
        }
        return paths.sorted { (rank($0), $0) < (rank($1), $1) }
    }

    static func isPointer(_ path: String) -> Bool {
        path.hasSuffix(pointerSuffix) && managedBlobPrefixes.contains(where: path.hasPrefix)
    }

    static func realPath(forPointer path: String) -> String {
        String(path.dropLast(pointerSuffix.count))
    }

    static func isMissingFile(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain, [NSFileReadNoSuchFileError, NSFileNoSuchFileError].contains(nsError.code) { return true }
        if nsError.domain == NSPOSIXErrorDomain, nsError.code == Int(ENOENT) { return true }
        return false
    }

    private static func sha256CacheKey(_ path: String) -> String { "sha256:" + path }

    private func cachedSHA256(path: String, size: Int, modified: Double) -> String? {
        if let cached = largeHashes[path], cached.size == size, abs(cached.modified.timeIntervalSince1970 - modified) < 0.001 {
            return cached.sha256
        }
        if let cached = blobHashes[Self.sha256CacheKey(path)], cached.size == size, abs(cached.modified - modified) < 0.001 {
            return cached.blobID
        }
        return nil
    }

    /// The pointer for a big file, from a cached SHA-256 while its size and date are unchanged.
    private func largeFile(at url: URL, path: String, size: Int, modified: Date) throws -> LargeFile {
        let sha: String
        if let cached = cachedSHA256(path: path, size: size, modified: modified.timeIntervalSince1970) {
            sha = cached
        } else {
            sha = try Hashing.sha256Hex(fileAt: url)
            largeHashes[path] = (size, modified, sha)
            // Kept with the blob ids, so a big file isn't read again every time the app opens.
            setBlobHash(Self.sha256CacheKey(path), CachedBlobHash(size: size, modified: modified.timeIntervalSince1970, blobID: sha))
        }
        let pointer = LargeFilePointer(path: path, size: size, sha256: sha)
        return LargeFile(url: url, pointer: pointer.encoded(), sha256: sha, size: size)
    }

    private func localFiles(remote: [String: String] = [:]) -> LocalScan {
        var scan = LocalScan()
        var readBudget = newFileReadBudget
        let manager = FileManager.default
        guard let enumerator = manager.enumerator(
            at: dataDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return scan }
        let rootPath = dataDirectory.standardizedFileURL.path
        var looked = 0
        for case let url as URL in enumerator {
            looked += 1
            if looked % 250 == 0 { activity.touch() }
            var path = url.standardizedFileURL.path
            guard path.hasPrefix(rootPath) else { continue }
            path.removeFirst(rootPath.count)
            while path.hasPrefix("/") { path.removeFirst() }
            guard Self.isManaged(path) else { continue }
            do {
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
                guard values.isRegularFile == true else { continue }
                // A pointer file never lives on the phone; one that does is ignored.
                if Self.isPointer(path) { continue }
                let size = values.fileSize ?? 0
                let modDate = values.contentModificationDate ?? .distantPast
                let modStamp = modDate.timeIntervalSince1970
                let isBlobFile = Self.managedBlobPrefixes.contains(where: path.hasPrefix)
                // A file too big for Git is saved as a pointer. This comes before the check
                // below: that one skipped every big file it had no id for, so on the first save
                // after the app opened, each pointer looked deleted here and was removed from
                // GitHub (all nine on 2 November), and new big files were never saved at all.
                if size >= largeFileThreshold, isBlobFile {
                    let pointerPath = path + Self.pointerSuffix
                    let known = cachedSHA256(path: path, size: size, modified: modStamp)
                    if known == nil, size > readBudget, readBudget < newFileReadBudget {
                        // Read it on a later pass; until then it's neither saved nor deleted.
                        scan.unreadablePaths.insert(path)
                        scan.unreadablePaths.insert(pointerPath)
                        scan.deferred.insert(pointerPath)
                        continue
                    }
                    if known == nil { readBudget -= size }
                    let large = try largeFile(at: url, path: path, size: size, modified: modDate)
                    scan.files[pointerPath] = Hashing.gitBlobID(large.pointer)
                    scan.largeFiles[pointerPath] = large
                    scan.largeRealPaths.insert(path)
                    continue
                }
                if let cached = blobHashes[path], cached.size == size, abs(cached.modified - modStamp) < 0.001 {
                    scan.files[path] = cached.blobID
                    continue
                }
                if size >= Self.rememberedFileBytes, isBlobFile {
                    // Do not read every big file again: one this phone has no record of at all (the
                    // record was lost, or this build reads it for the first time) takes the id
                    // already agreed, or GitHub's. A file with a record whose size or date no longer
                    // matches has been edited, so it is read again below. Taking the old id for it
                    // too (and recording that under the new size and date) meant an edited file of
                    // 1 to 20 MB never went up at all.
                    if blobHashes[path] == nil, let agreed = state.files[path] ?? remote[path] {
                        setBlobHash(path, CachedBlobHash(size: size, modified: modStamp, blobID: agreed))
                        scan.files[path] = agreed
                        continue
                    }
                    // A brand-new big file is read once, a piece at a time, within this scan's
                    // budget; the rest wait for the next pass. They used to be skipped for good.
                    if size > readBudget, readBudget < newFileReadBudget {
                        scan.unreadablePaths.insert(path)
                        scan.deferred.insert(path)
                        continue
                    }
                    readBudget -= size
                }
                let blobID = try Hashing.gitBlobID(fileAt: url)
                setBlobHash(path, CachedBlobHash(size: size, modified: modStamp, blobID: blobID))
                scan.files[path] = blobID
            } catch where Self.isMissingFile(error) {
                // Gone between listing and reading: deleted, not unreadable.
                continue
            } catch {
                scan.unreadablePaths.insert(path)
                scan.problems.append(FileProblem(path: path, stage: .read, message: error.localizedDescription))
            }
        }
        saveHashCache()
        for record in Quarantine.records(dataDirectory: dataDirectory) where scan.files[record.originalPath] == nil {
            scan.unreadablePaths.insert(record.originalPath)
            scan.problems.append(FileProblem(path: record.originalPath, stage: .read, message: "Stored file was quarantined: \(record.reason)"))
        }
        return scan
    }

    private func currentBlobID(at url: URL) -> String? {
        try? Hashing.gitBlobID(fileAt: url)
    }

    /// The blob id this path has on the phone right now; for a pointer, the pointer of the big
    /// file it stands for.
    private func currentBlobID(forPath path: String) -> String? {
        guard Self.isPointer(path) else { return currentBlobID(at: dataDirectory.appendingPathComponent(path)) }
        let real = Self.realPath(forPointer: path)
        let url = dataDirectory.appendingPathComponent(real)
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]), let size = values.fileSize,
              let large = try? largeFile(at: url, path: real, size: size, modified: values.contentModificationDate ?? .distantPast)
        else { return nil }
        return Hashing.gitBlobID(large.pointer)
    }

    private func fetchBlobsIsolated(_ repo: RepoRef, paths: [String], ids: [String: String]) async -> [String: Result<Data, Error>] {
        await withTaskGroup(of: (String, Result<Data, Error>).self) { group in
            var results: [String: Result<Data, Error>] = [:]
            var pending = paths.makeIterator()
            func addNext() {
                while let path = pending.next() {
                    guard let sha = ids[path] else { continue }
                    group.addTask { [github] in
                        do { return (path, .success(try await github.blob(repo, sha: sha))) }
                        catch { return (path, .failure(error)) }
                    }
                    return
                }
            }
            for _ in 0..<6 { addNext() }
            while let (path, outcome) = await group.next() {
                results[path] = outcome
                activity.touch()
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



/// A big attachment or media file kept as a release asset.
struct LargeFile: Sendable {
    var url: URL
    var pointer: Data
    var sha256: String
    var size: Int
    var assetName: String { sha256 + ".bin" }
}

/// What Git keeps in place of a big file: where it goes, how big it is, and its SHA-256.
struct LargeFilePointer: Codable, Sendable, Hashable {
    var format = 1
    var path: String
    var size: Int
    var sha256: String
    var storage = "release-asset"

    init(path: String, size: Int, sha256: String) {
        self.path = path
        self.size = size
        self.sha256 = sha256
    }

    func encoded() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return (try? encoder.encode(self)) ?? Data()
    }

    static func parse(_ data: Data) -> LargeFilePointer? {
        guard let pointer = try? JSONDecoder().decode(LargeFilePointer.self, from: data),
              pointer.format == 1, pointer.sha256.count == 64, pointer.sha256.allSatisfy(\.isHexDigit),
              pointer.size >= 0, SnapshotStore.isSafeRelativePath(pointer.path)
        else { return nil }
        return pointer
    }
}

/// Uploads and fetches big files in MAIPA-G-data's private files release, once per file.
actor LargeFileStore {
    private let github: GitHubClient
    private let repo: RepoRef
    private let releaseID: Int
    private var assets: [String: GitHubClient.ReleaseAsset]

    init(github: GitHubClient, repo: RepoRef) async throws {
        self.github = github
        self.repo = repo
        releaseID = try await github.filesRelease(repo)
        assets = Dictionary(try await github.releaseAssets(repo, releaseID: releaseID).map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Uploads the file unless the release already has these exact bytes.
    func ensure(_ file: LargeFile) async throws {
        if let existing = assets[file.assetName], existing.isUploaded, existing.size == file.size { return }
        // A "starter" asset (full size, no bytes yet) is either an upload still going (one left
        // running in the background when an earlier save stopped, which the app's transport picks
        // up again instead of starting a second) or one that was cut off. Uploading first lets the
        // first kind finish; for the second, GitHub refuses the name, the upload removes the
        // cut-off copy and says so (409), and the whole file goes up once more.
        let uploaded: GitHubClient.ReleaseAsset
        do {
            uploaded = try await github.uploadReleaseAsset(repo, releaseID: releaseID, name: file.assetName, file: file.url)
        } catch let error as GitHubAPIError where error.status == 409 {
            assets[file.assetName] = nil
            uploaded = try await github.uploadReleaseAsset(repo, releaseID: releaseID, name: file.assetName, file: file.url)
        }
        assets[uploaded.name] = uploaded
    }

    /// Downloads the file a pointer names, checks its size and SHA-256, then puts it in place.
    func fetch(_ pointer: LargeFilePointer, into dataDirectory: URL) async throws {
        guard let asset = assets[pointer.sha256 + ".bin"], asset.isUploaded else {
            throw GitHubAPIError(status: 404, message: "\(pointer.path) isn't in MAIPA-G-data's files release yet; the phone that has it will upload it")
        }
        let destination = dataDirectory.appendingPathComponent(pointer.path)
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).download")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try await github.downloadReleaseAsset(repo, assetID: asset.id, to: temporary)
        let size = (try? FileManager.default.attributesOfItem(atPath: temporary.path)[.size] as? Int) ?? -1
        guard size == pointer.size, try Hashing.sha256Hex(fileAt: temporary) == pointer.sha256 else {
            throw GitHubAPIError(status: 0, message: "The download of \(pointer.path) didn't match its saved checksum, so it wasn't used")
        }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: destination)
        }
    }
}

/// What a running backup pass has done, readable from anywhere while it runs (the app's status
/// line), and a way to ask it to wrap up early (the app is going to the background).
public final class SyncPassMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private var finishAt: TimeInterval?
    private var committed = 0
    private var left: Int?

    public init() {}

    /// Asks the running pass, and any that start before `clearFinish()`, to start no more uploads
    /// once `seconds` have passed, commit what it has sent, and return normally.
    public func finish(within seconds: TimeInterval) {
        let at = ProcessInfo.processInfo.systemUptime + max(seconds, 0)
        lock.withLock { finishAt = at }
    }

    public func clearFinish() {
        lock.withLock { finishAt = nil }
    }

    /// Seconds until the pass should wrap up, or nil when it has no deadline.
    public func secondsUntilFinish() -> TimeInterval? {
        let now = ProcessInfo.processInfo.systemUptime
        return lock.withLock { finishAt.map { $0 - now } }
    }

    /// Files committed by this phone's backup since the app opened. It only grows, so a caller can
    /// tell whether a pass that was stopped had saved anything first.
    public var committedFiles: Int { lock.withLock { committed } }

    /// Files the running pass still has to send, when it knows.
    public var filesLeft: Int? { lock.withLock { left } }

    func noteCommitted(_ count: Int) {
        lock.withLock { committed += count }
    }

    func setFilesLeft(_ count: Int?) {
        lock.withLock { left = count }
    }
}
