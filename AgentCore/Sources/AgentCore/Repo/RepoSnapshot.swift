import Foundation

/// One file in a local copy of a repo.
public struct SnapshotFile: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable {
        /// Stored on the phone and searchable.
        case text
        /// Pictures, archives and the like: listed, not stored.
        case binary
        /// Larger than `SnapshotStore.maxStoredFileSize`: listed, not stored.
        case tooLarge
        case symlink
    }

    public var path: String
    public var size: Int
    public var kind: Kind
    public var linkTarget: String?

    public init(path: String, size: Int, kind: Kind, linkTarget: String? = nil) {
        self.path = path
        self.size = size
        self.kind = kind
        self.linkTarget = linkTarget
    }
}

public struct SnapshotManifest: Codable, Sendable {
    public var formatVersion: Int
    public var repo: RepoRef
    public var commit: String
    public var createdAt: Date
    /// Sorted by path.
    public var files: [SnapshotFile]

    public var storedBytes: Int { files.filter { $0.kind == .text }.reduce(0) { $0 + $1.size } }
}

/// A complete, read-only copy of a repo's text files at one commit, kept in the phone's caches.
public struct RepoSnapshot: Sendable {
    public let repo: RepoRef
    public let commit: String
    public let directory: URL
    public let manifest: SnapshotManifest
    private let index: [String: Int]

    init(directory: URL, manifest: SnapshotManifest) {
        self.repo = manifest.repo
        self.commit = manifest.commit
        self.directory = directory
        self.manifest = manifest
        var index: [String: Int] = [:]
        for (position, file) in manifest.files.enumerated() { index[file.path] = position }
        self.index = index
    }

    var filesDirectory: URL { directory.appendingPathComponent("files", isDirectory: true) }

    public func file(_ path: String) -> SnapshotFile? {
        index[path].map { manifest.files[$0] }
    }

    public func url(for path: String) -> URL {
        filesDirectory.appendingPathComponent(path, isDirectory: false)
    }

    /// The bytes of a stored text file, or nil if the copy does not hold it.
    public func contents(of path: String) -> Data? {
        guard file(path)?.kind == .text else { return nil }
        return try? Data(contentsOf: url(for: path), options: .mappedIfSafe)
    }
}

public enum SnapshotProgress: Sendable, Equatable {
    case downloading(bytes: Int64)
    case unpacking(files: Int)
    case updating(changed: Int)
}

/// Keeps local copies of repos so the AI can search them, one folder per commit.
///
/// A first copy comes from GitHub's tarball of the commit, streamed to disk and unpacked as it
/// arrives. When the branch moves on, the next copy is the previous one cloned (instant on the
/// iPhone's file system) with only the changed files fetched. Copies are immutable once made, so a
/// chat that is mid-answer never sees files change under it.
public actor SnapshotStore {
    public static let maxStoredFileSize = 2 * 1024 * 1024
    /// Git's own test for "binary": a zero byte in the first 8,000 bytes.
    static let binarySniffLength = 8_000
    static let copiesPerRepo = 3

    public let root: URL
    private let maxCacheBytes: Int64
    private var inFlight: [String: Task<RepoSnapshot, Error>] = [:]

    public init(root: URL, maxCacheBytes: Int64 = 2 * 1024 * 1024 * 1024) {
        self.root = root
        self.maxCacheBytes = maxCacheBytes
    }

    private func repoDirectory(_ repo: RepoRef) -> URL {
        root.appendingPathComponent(Self.safeName(repo.owner), isDirectory: true)
            .appendingPathComponent(Self.safeName(repo.name), isDirectory: true)
    }

    private func snapshotDirectory(_ repo: RepoRef, commit: String) -> URL {
        repoDirectory(repo).appendingPathComponent(commit, isDirectory: true)
    }

    static func safeName(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let cleaned = String(name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
        return cleaned.hasPrefix(".") ? "_" + cleaned : cleaned
    }

    /// The copy for `commit`, if one is already on the phone.
    public func cachedSnapshot(_ repo: RepoRef, commit: String) -> RepoSnapshot? {
        let directory = snapshotDirectory(repo, commit: commit)
        let manifestURL = directory.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONCoding.decoder().decode(SnapshotManifest.self, from: data),
              manifest.formatVersion == 1
        else { return nil }
        touch(directory)
        return RepoSnapshot(directory: directory, manifest: manifest)
    }

    /// The copy for `commit`, made now if needed. Callers asking for the same copy at the same
    /// time share one download.
    public func snapshot(
        _ repo: RepoRef,
        commit: String,
        github: GitHubClient,
        progress: @escaping @Sendable (SnapshotProgress) -> Void = { _ in }
    ) async throws -> RepoSnapshot {
        if let existing = cachedSnapshot(repo, commit: commit) { return existing }
        let key = repo.fullName + "@" + commit
        if let running = inFlight[key] { return try await running.value }
        let base = latestSnapshot(of: repo)
        let task = Task { [root] in
            try await Self.build(repo: repo, commit: commit, base: base, root: root, github: github, progress: progress)
        }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        let snapshot = try await task.value
        prune(repo)
        return snapshot
    }

    /// Frees space: all copies, or everything but the newest of each repo.
    public func removeAll() {
        try? FileManager.default.removeItem(at: root)
    }

    public func diskUsage() -> Int64 {
        Self.allocatedSize(of: root)
    }

    // MARK: Building

    private static func build(
        repo: RepoRef,
        commit: String,
        base: RepoSnapshot?,
        root: URL,
        github: GitHubClient,
        progress: @escaping @Sendable (SnapshotProgress) -> Void
    ) async throws -> RepoSnapshot {
        let manager = FileManager.default
        let repoDirectory = root.appendingPathComponent(safeName(repo.owner), isDirectory: true)
            .appendingPathComponent(safeName(repo.name), isDirectory: true)
        try manager.createDirectory(at: repoDirectory, withIntermediateDirectories: true)
        let partial = repoDirectory.appendingPathComponent(".partial-\(UUID().uuidString)", isDirectory: true)
        defer { try? manager.removeItem(at: partial) }

        var manifest: SnapshotManifest?
        if let base {
            manifest = try await updateFrom(base: base, to: commit, into: partial, github: github, progress: progress)
        }
        if manifest == nil {
            try? manager.removeItem(at: partial)
            manifest = try await downloadFresh(repo: repo, commit: commit, into: partial, github: github, progress: progress)
        }
        guard let manifest else { throw SnapshotError.failed("No copy was made") }

        let manifestData = try JSONCoding.encoder().encode(manifest)
        try manifestData.write(to: partial.appendingPathComponent("manifest.json"), options: .atomic)
        let final = repoDirectory.appendingPathComponent(commit, isDirectory: true)
        if manager.fileExists(atPath: final.path) {
            // Another copy of the same commit finished first; keep that one.
            try? manager.removeItem(at: partial)
        } else {
            try manager.moveItem(at: partial, to: final)
        }
        let finishedManifest = (try? Data(contentsOf: final.appendingPathComponent("manifest.json")))
            .flatMap { try? JSONCoding.decoder().decode(SnapshotManifest.self, from: $0) } ?? manifest
        return RepoSnapshot(directory: final, manifest: finishedManifest)
    }

    /// Downloads the tarball and unpacks the text files from it as the bytes arrive on disk.
    private static func downloadFresh(
        repo: RepoRef,
        commit: String,
        into directory: URL,
        github: GitHubClient,
        progress: @escaping @Sendable (SnapshotProgress) -> Void
    ) async throws -> SnapshotManifest {
        let manager = FileManager.default
        let filesDirectory = directory.appendingPathComponent("files", isDirectory: true)
        try manager.createDirectory(at: filesDirectory, withIntermediateDirectories: true)
        let archive = directory.appendingPathComponent("download.tar.gz")
        try await github.downloadTarball(repo, ref: commit, to: archive) { bytes in
            progress(.downloading(bytes: bytes))
        }
        try Task.checkCancellation()

        var unpacker = SnapshotUnpacker(filesDirectory: filesDirectory)
        let inflater = try GzipInflater()
        var tar = TarReader()
        let handle = try FileHandle(forReadingFrom: archive)
        defer { try? handle.close() }
        var lastReported = 0
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            try Task.checkCancellation()
            try inflater.feed(chunk) { piece in
                try tar.feed(piece, into: &unpacker)
            }
            if unpacker.files.count - lastReported >= 200 {
                lastReported = unpacker.files.count
                progress(.unpacking(files: lastReported))
            }
            if tar.isDone { break }
        }
        try? manager.removeItem(at: archive)
        progress(.unpacking(files: unpacker.files.count))
        return SnapshotManifest(
            formatVersion: 1,
            repo: repo,
            commit: commit,
            createdAt: Date(),
            files: unpacker.files.sorted { $0.path < $1.path }
        )
    }

    /// Makes the new copy from an older one plus the files that changed. Returns nil when that is
    /// not possible (the branch was rewritten, or too much changed) so a fresh download is used.
    private static func updateFrom(
        base: RepoSnapshot,
        to commit: String,
        into directory: URL,
        github: GitHubClient,
        progress: @escaping @Sendable (SnapshotProgress) -> Void
    ) async throws -> SnapshotManifest? {
        guard let comparison = try? await github.compare(base.repo, base: base.commit, head: commit) else { return nil }
        // Only "ahead" means the old commit is an ancestor, so the listed changes lead from it to
        // the new one. "behind" and "diverged" list changes from a common ancestor instead.
        guard comparison.status == "ahead" || comparison.status == "identical", comparison.isComplete,
              comparison.files.count <= 300
        else { return nil }

        let manager = FileManager.default
        do {
            // On APFS this is a clone: instant, and it takes no extra space until a file changes.
            try manager.copyItem(at: base.directory, to: directory)
        } catch {
            return nil
        }
        try? manager.removeItem(at: directory.appendingPathComponent("manifest.json"))
        let filesDirectory = directory.appendingPathComponent("files", isDirectory: true)

        var files: [String: SnapshotFile] = [:]
        for file in base.manifest.files { files[file.path] = file }

        var fetches: [(path: String, sha: String)] = []
        for change in comparison.files {
            guard isSafeRelativePath(change.path) else { continue }
            if let previous = change.previousPath, previous != change.path, isSafeRelativePath(previous) {
                files[previous] = nil
                try? manager.removeItem(at: filesDirectory.appendingPathComponent(previous))
            }
            if change.status == "removed" {
                files[change.path] = nil
                try? manager.removeItem(at: filesDirectory.appendingPathComponent(change.path))
            } else if let sha = change.sha {
                try? manager.removeItem(at: filesDirectory.appendingPathComponent(change.path))
                fetches.append((change.path, sha))
            }
        }

        progress(.updating(changed: fetches.count))
        let fetched = try await withThrowingTaskGroup(of: (String, Data).self) { group in
            var results: [(String, Data)] = []
            var iterator = fetches.makeIterator()
            for _ in 0..<min(8, fetches.count) {
                if let next = iterator.next() {
                    group.addTask { (next.path, try await github.blob(base.repo, sha: next.sha)) }
                }
            }
            while let result = try await group.next() {
                results.append(result)
                if let next = iterator.next() {
                    group.addTask { (next.path, try await github.blob(base.repo, sha: next.sha)) }
                }
            }
            return results
        }

        for (path, data) in fetched {
            let kind: SnapshotFile.Kind
            if data.count > maxStoredFileSize {
                kind = .tooLarge
            } else if data.prefix(binarySniffLength).contains(0) {
                kind = .binary
            } else {
                kind = .text
                let url = filesDirectory.appendingPathComponent(path)
                try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url)
            }
            files[path] = SnapshotFile(path: path, size: data.count, kind: kind)
        }

        return SnapshotManifest(
            formatVersion: 1,
            repo: base.repo,
            commit: commit,
            createdAt: Date(),
            files: files.values.sorted { $0.path < $1.path }
        )
    }

    // MARK: Housekeeping

    private func latestSnapshot(of repo: RepoRef) -> RepoSnapshot? {
        let directory = repoDirectory(repo)
        guard let entries = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }
        let candidates = entries
            .filter { !$0.lastPathComponent.hasPrefix(".") }
            .sorted { Self.modified($0) > Self.modified($1) }
        for candidate in candidates {
            if let snapshot = cachedSnapshot(repo, commit: candidate.lastPathComponent) { return snapshot }
        }
        return nil
    }

    /// Keeps the newest few copies of `repo`, then trims the oldest copies of any repo while the
    /// cache is over its size limit.
    private func prune(_ repo: RepoRef) {
        let manager = FileManager.default
        let directory = repoDirectory(repo)
        if let entries = try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) {
            let copies = entries.filter { !$0.lastPathComponent.hasPrefix(".") }.sorted { Self.modified($0) > Self.modified($1) }
            for old in copies.dropFirst(Self.copiesPerRepo) { try? manager.removeItem(at: old) }
            // Leftovers from a copy that was interrupted (the app closed mid-download).
            for partial in entries where partial.lastPathComponent.hasPrefix(".partial-") && Self.modified(partial) < Date().addingTimeInterval(-3600) {
                try? manager.removeItem(at: partial)
            }
        }
        var all: [(url: URL, modified: Date, size: Int64)] = []
        for owner in (try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            for name in (try? manager.contentsOfDirectory(at: owner, includingPropertiesForKeys: nil)) ?? [] {
                for copy in (try? manager.contentsOfDirectory(at: name, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
                where !copy.lastPathComponent.hasPrefix(".") {
                    all.append((copy, Self.modified(copy), Self.allocatedSize(of: copy)))
                }
            }
        }
        var total = all.reduce(0) { $0 + $1.size }
        for copy in all.sorted(by: { $0.modified < $1.modified }) where total > maxCacheBytes {
            try? manager.removeItem(at: copy.url)
            total -= copy.size
        }
    }

    private func touch(_ directory: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: directory.path)
    }

    static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    static func allocatedSize(of directory: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true { total += Int64(values?.fileSize ?? 0) }
        }
        return total
    }

    /// A path inside the repo that cannot escape it: relative, no "..", no empty parts.
    public static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0") else { return false }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return !parts.contains { $0.isEmpty || $0 == ".." || $0 == "." }
    }
}

public enum SnapshotError: Error, Sendable, CustomStringConvertible {
    case failed(String)
    public var description: String {
        switch self {
        case .failed(let message): return message
        }
    }
}

/// Writes the text files of a GitHub tarball to disk as they stream out of it.
struct SnapshotUnpacker: TarHandler {
    let filesDirectory: URL
    private(set) var files: [SnapshotFile] = []
    private(set) var commitComment: String?

    private var current: (path: String, size: Int)?
    private var head = Data()
    private var decided: SnapshotFile.Kind?
    private var handle: FileHandle?
    private var createdDirectories: Set<String> = []

    init(filesDirectory: URL) {
        self.filesDirectory = filesDirectory
    }

    /// GitHub's tarballs put everything in one top folder named "<owner>-<repo>-<short id>",
    /// taken from the first entry. Anything outside it is ignored.
    private var topFolder: String?

    /// The path inside the repo, or nil for the top folder itself and for anything outside it.
    mutating func repoPath(_ archivePath: String) -> String? {
        guard let slash = archivePath.firstIndex(of: "/") else { return nil }
        let top = String(archivePath[..<slash])
        if topFolder == nil {
            guard !top.isEmpty, top != ".", top != ".." else { return nil }
            topFolder = top
        }
        guard top == topFolder else { return nil }
        var rest = String(archivePath[archivePath.index(after: slash)...])
        if rest.hasSuffix("/") { rest.removeLast() }
        guard SnapshotStore.isSafeRelativePath(rest) else { return nil }
        return rest
    }

    mutating func globalComment(_ comment: String) {
        commitComment = comment
    }

    mutating func begin(_ entry: TarEntry) throws -> Bool {
        guard let path = repoPath(entry.path) else { return false }
        switch entry.kind {
        case .symlink:
            files.append(SnapshotFile(path: path, size: 0, kind: .symlink, linkTarget: entry.linkTarget))
            return false
        case .file:
            if entry.size > SnapshotStore.maxStoredFileSize {
                files.append(SnapshotFile(path: path, size: entry.size, kind: .tooLarge))
                return false
            }
            current = (path, entry.size)
            head.removeAll(keepingCapacity: true)
            decided = nil
            if entry.size == 0 {
                decided = .text
                try openFile()
            }
            return true
        default:
            return false
        }
    }

    mutating func data(_ bytes: UnsafeRawBufferPointer) throws {
        guard current != nil else { return }
        switch decided {
        case .text:
            try handle?.write(contentsOf: bytes)
        case .binary, .tooLarge, .symlink:
            return
        case nil:
            head.append(contentsOf: bytes)
            if head.count >= SnapshotStore.binarySniffLength {
                try decide()
            }
        }
    }

    mutating func end() throws {
        guard let current else { return }
        if decided == nil { try decide() }
        try? handle?.close()
        handle = nil
        files.append(SnapshotFile(path: current.path, size: current.size, kind: decided ?? .text))
        self.current = nil
    }

    private mutating func decide() throws {
        if head.prefix(SnapshotStore.binarySniffLength).contains(0) {
            decided = .binary
        } else {
            decided = .text
            try openFile()
            try handle?.write(contentsOf: head)
        }
        head.removeAll(keepingCapacity: true)
    }

    private mutating func openFile() throws {
        guard let current else { return }
        let url = filesDirectory.appendingPathComponent(current.path, isDirectory: false)
        let folder = url.deletingLastPathComponent()
        if !createdDirectories.contains(folder.path) {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            createdDirectories.insert(folder.path)
        }
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw SnapshotError.failed("Could not save \(current.path)")
        }
        handle = try FileHandle(forWritingTo: url)
    }
}
