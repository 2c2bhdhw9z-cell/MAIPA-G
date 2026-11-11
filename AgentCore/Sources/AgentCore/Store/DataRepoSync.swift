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
    static let managedJSONPrefixes = ["chats/", "memories/", "agents/", "workflows/", "groups/", "jobs/", "connectors/", "specs/", "receipts/", "drafts/", "trash/", "diagnostics/", "autonomous-installations/"]
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
        /// Files left for the next pass because this one reached its size, count or time budget.
        /// The caller runs another pass straight away; nothing here is lost or counted as deleted.
        public var deferred: [String] = []

        public var hasMoreToSave: Bool { !deferred.isEmpty }

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

    private let github: GitHubClient
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
    /// Pictures and other big attachments at least this size are not read again when this phone
    /// already agreed on their id. Reading all of them on open is what was closing the app.
    private static let rememberedFileBytes = 1024 * 1024
    /// How many bytes of brand-new big files one scan may read to work out their ids. The rest
    /// wait for the next pass, so a big import never means reading every file at once.
    var newFileReadBudget = 48 * 1024 * 1024

    /// One pass uploads at most this much and then commits it, so a backlog is saved in pieces.
    /// Before, every pending file had to go up inside a single 3-minute window and nothing was
    /// committed until all of them had; a big backlog timed out, threw the finished uploads
    /// away and started again from nothing, every time (and used up GitHub's hourly limit).
    var uploadFileLimit = 120
    var uploadByteLimit = 40 * 1024 * 1024
    var uploadTimeLimit: TimeInterval = 75

    /// Touched after every step that reached GitHub, so whoever is waiting can tell a slow but
    /// moving save from a stuck one.
    public nonisolated let activity = ActivityClock()
    private var running: Task<Void, Never>?

    /// A big file's upload or download sends no progress of its own, so it keeps `activity` alive
    /// for as long as that many bytes may fairly take (100 KB/s at the slowest, at least 3 minutes);
    /// past that it counts as stuck like anything else.
    @discardableResult
    private func withHeartbeat<T: Sendable>(bytes: Int, _ work: @Sendable () async throws -> T) async throws -> T {
        let clock = activity
        let allowance = max(180, Double(bytes) / 100_000)
        let beat = Task {
            let started = ProcessInfo.processInfo.systemUptime
            while !Task.isCancelled, ProcessInfo.processInfo.systemUptime - started < allowance {
                clock.touch()
                try? await Task.sleep(nanoseconds: 15_000_000_000)
            }
        }
        defer { beat.cancel() }
        let value = try await work()
        clock.touch()
        return value
    }

    /// For tests: smaller passes.
    func setPassLimits(files: Int? = nil, bytes: Int? = nil, seconds: TimeInterval? = nil, newFileReadBytes: Int? = nil) {
        if let files { uploadFileLimit = files }
        if let bytes { uploadByteLimit = bytes }
        if let seconds { uploadTimeLimit = seconds }
        if let newFileReadBytes { newFileReadBudget = newFileReadBytes }
    }

    public init(github: GitHubClient, dataDirectory: URL, stateURL: URL, largeFileThreshold: Int = DataRepoSync.defaultLargeFileThreshold) {
        self.github = github
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
        blobHashes = [:]
        saveState()
        try? FileManager.default.removeItem(at: Self.hashCacheURL(for: stateURL))
    }

    private nonisolated static func hashCacheURL(for stateURL: URL) -> URL {
        stateURL.deletingLastPathComponent().appendingPathComponent("blob-hash-cache.json")
    }

    private func saveHashCache() {
        let url = Self.hashCacheURL(for: stateURL)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONCoding.encoder().encode(blobHashes).write(to: url, options: .atomic)
    }

    private static func isRefConflict(_ error: GitHubAPIError) -> Bool {
        if error.status == 409 { return true }
        guard error.status == 422 else { return false }
        let lower = error.message.lowercased()
        return lower.contains("fast forward") || lower.contains("fast-forward") || lower.contains("reference")
    }

    /// Brings the phone and GitHub into line. Safe to call often; does nothing when nothing changed.
    @discardableResult
    public func sync() async throws -> Report {
        // A sync the app stopped waiting for (it went quiet too long) may still be winding down.
        // Two at once would each commit from the same starting point, so wait for it.
        while let previous = running { await previous.value }
        let (finished, finish) = AsyncStream<Void>.makeStream()
        let marker = Task { for await _ in finished {} }
        running = marker
        defer {
            finish.finish()
            if running == marker { running = nil }
        }
        var attempt = 0
        while true {
            attempt += 1
            do {
                return try await syncOnce()
            } catch let error as GitHubAPIError where Self.isRefConflict(error) && attempt < 4 {
                // The branch moved while we were working: someone else saved. Start over after brief backoff.
                try? await Task.sleep(nanoseconds: UInt64(attempt) * 120_000_000)
                continue
            }
        }
    }

    private func syncOnce() async throws -> Report {
        guard let repo = state.repo, let branch = state.branch else { throw Failure.notSetUp }
        var report = Report()
        activity.touch()
        let head = try await github.branchHead(repo, branch: branch)
        activity.touch()

        var remote: [String: String]
        if head == state.lastCommit {
            remote = state.files
        } else if let head {
            // Listing every file can take a while on a slow connection; it isn't a stuck save.
            let tree = try await withHeartbeat(bytes: 0) { [github] in
                try await github.tree(repo, sha: try await github.commitTree(repo, commit: head), recursive: true)
            }
            remote = [:]
            for entry in tree.entries where entry.isFile && Self.isManaged(entry.path) { remote[entry.path] = entry.sha }
        } else {
            remote = [:]
        }
        let scan = localFiles(remote: remote)
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
        var skipped = scan.unreadablePaths
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
                    let fetchStore = downloadStore, directory = dataDirectory
                    try await withHeartbeat(bytes: pointer.size) { try await fetchStore?.fetch(pointer, into: directory) }
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
                    blobHashes[path] = CachedBlobHash(
                        size: vals.fileSize ?? diskBytes.count,
                        modified: (vals.contentModificationDate ?? Date()).timeIntervalSince1970,
                        blobID: diskBlob
                    )
                }
            }
        }

        // Phone to GitHub. Read/blob failures are isolated; every successful file and deletion is
        // still committed together, while failed paths remain pending for the next sync.
        var changes: [GitHubClient.TreeChange] = []
        var successfulUploads: [String] = []
        var store: LargeFileStore?
        let passStarted = ProcessInfo.processInfo.systemUptime
        var startedUploads = 0
        var startedBytes = 0
        // Every file GitHub already has, by content. Attaching the same file again (or many
        // copies of it at once) used to upload every copy; GitHub keeps one, so the others were
        // bytes sent for nothing, and on a phone connection they made the save time out.
        var storedBlobs = Set(remote.values).union(base.values)
        for path in Self.uploadOrder(uploads) {
            try Task.checkCancellation()
            let url = dataDirectory.appendingPathComponent(path)
            if !path.hasPrefix("chats/"), scan.largeFiles[path] == nil, let blob = local[path], storedBlobs.contains(blob) {
                changes.append(GitHubClient.TreeChange(path: path, blobSHA: blob))
                successfulUploads.append(path)
                continue
            }
            let size = scan.largeFiles[path]?.size
                ?? ((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            // Past this pass's budget: leave the rest for the next pass, which starts as soon as
            // this one is committed. At least one file always goes, so every pass makes progress.
            // A file that would take the pass past its byte budget waits for the next one.
            let largeOnes = scan.largeFiles[path] != nil
            if startedUploads > 0,
               startedUploads >= uploadFileLimit || (!largeOnes && startedBytes + size > uploadByteLimit)
                || ProcessInfo.processInfo.systemUptime - passStarted >= uploadTimeLimit {
                agreed[path] = base[path]
                report.deferred.append(path)
                continue
            }
            startedUploads += 1
            startedBytes += size
            do {
                let data: Data
                if let large = scan.largeFiles[path] {
                    if store == nil { store = try await LargeFileStore(github: github, repo: repo) }
                    let largeStore = store
                    try await withHeartbeat(bytes: large.size) { try await largeStore?.ensure(large) }
                    data = large.pointer
                } else {
                    let raw = try Data(contentsOf: url)
                    if path.hasPrefix("chats/") {
                        let safe = (try? SensitiveDataRedactor().redactJSON(raw)) ?? raw
                        if safe != raw {
                            try? safe.write(to: url, options: .atomic)
                            if let vals = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) {
                                blobHashes[path] = CachedBlobHash(
                                    size: vals.fileSize ?? safe.count,
                                    modified: (vals.contentModificationDate ?? Date()).timeIntervalSince1970,
                                    blobID: Hashing.gitBlobID(safe)
                                )
                            }
                        }
                        data = safe
                    } else {
                        data = raw
                    }
                }
                // Sent as base64, a third bigger. A 17 MB file on a slow phone connection can take
                // longer than the save's three quiet minutes, so the upload keeps the save alive
                // for as long as its size fairly needs.
                let blob: String
                let known = Hashing.gitBlobID(data)
                if storedBlobs.contains(known) {
                    blob = known
                } else {
                    blob = try await withHeartbeat(bytes: data.count * 4 / 3) { [github] in try await github.createBlob(repo, contents: data) }
                }
                storedBlobs.insert(blob)
                changes.append(GitHubClient.TreeChange(path: path, blobSHA: blob))
                successfulUploads.append(path)
            } catch let error as GitHubAPIError where error.isRateLimited {
                // Every further request would be refused too (and each waits before failing),
                // so stop here; the coordinator tries again once the limit resets.
                throw error
            } catch where Self.isMissingFile(error) {
                // Deleted or replaced on the phone after this sync looked at it: not a failure.
                // The next sync sees what is there now.
                agreed[path] = base[path]
            } catch {
                agreed[path] = base[path]
                report.problems.append(FileProblem(path: path, stage: .upload, message: ErrorExplainer.describe(error).message))
            }
        }
        // A file moving from Git to the files release keeps its Git copy until the release copy
        // and its pointer are saved.
        let unsavedLargeFiles = Set(uploads.filter { Self.isPointer($0) && !successfulUploads.contains($0) }.map(Self.realPath(forPointer:)))
        report.deferred = Array(Set(report.deferred).union(scan.deferred)).sorted()
        let committedDeletes = deleteThere.filter { remote[$0] != nil && !unsavedLargeFiles.contains($0) }
        for path in deleteThere where unsavedLargeFiles.contains(path) { agreed[path] = base[path] }
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
            activity.touch()
            let commit = try await github.createCommit(repo, message: Self.commitMessage(uploads: successfulUploads, deletes: committedDeletes), tree: tree, parents: head.map { [$0] } ?? [])
            activity.touch()
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
            blobHashes[Self.sha256CacheKey(path)] = CachedBlobHash(size: size, modified: modified.timeIntervalSince1970, blobID: sha)
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
                    // Do not read every big file again. Reuse the id already agreed, or GitHub's.
                    if let agreed = state.files[path] ?? remote[path] {
                        blobHashes[path] = CachedBlobHash(size: size, modified: modStamp, blobID: agreed)
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
                blobHashes[path] = CachedBlobHash(size: size, modified: modStamp, blobID: blobID)
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
        if let existing = assets[file.assetName] {
            if existing.isUploaded, existing.size == file.size { return }
            // A cut-off earlier upload ("starter") reports the full size but holds nothing, and
            // blocks the name. Remove it so the whole file goes up.
            if !existing.isUploaded {
                try await github.deleteReleaseAsset(repo, assetID: existing.id)
                assets[file.assetName] = nil
            }
        }
        let uploaded = try await github.uploadReleaseAsset(repo, releaseID: releaseID, name: file.assetName, file: file.url)
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
