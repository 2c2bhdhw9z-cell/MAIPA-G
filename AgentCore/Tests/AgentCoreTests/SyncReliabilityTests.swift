import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import AgentCore

/// FakeGitHub with the parts of GitHub that make saving unreliable in real life: a file list cut
/// short (`truncated`), rate limits with `retry-after`, dropped connections, slow uploads, and
/// counts of every request so the number of calls can be checked.
final class UnreliableGitHub: HTTPTransport, @unchecked Sendable {
    enum Drop { case beforeLanding, afterLanding }
    enum TreeFailure { case offline, refused, rateLimited }

    let fake = FakeGitHub()
    private let lock = NSLock()

    /// The one-call (recursive) listing of the whole repo comes back cut short.
    var truncateWholeListing = false
    /// Recursive listings of these folders ("chats/") come back cut short.
    var truncatedFolders: Set<String> = []
    /// Even the one-level listing of these folders comes back cut short.
    var truncatedFolderLevels: Set<String> = []
    /// Blob uploads after this many are refused with a secondary rate limit (retry-after 120).
    var blobLimitAfter: Int?
    /// The next blob upload is answered 429 with `retry-after: 1`.
    var shortRetryAfterOnce = false
    var failNextTree: TreeFailure?
    var dropNextRefUpdate: Drop?
    var blobDelay: TimeInterval = 0
    /// Called with each blob upload's number, as it arrives.
    var onBlob: (@Sendable (Int) -> Void)?
    /// Checked during a slow blob upload: how long the backup had been quiet before and after the
    /// upload reported its progress.
    var watchedActivity: ActivityClock?
    private(set) var quietBeforeProgress: [TimeInterval] = []
    private(set) var quietAfterProgress: [TimeInterval] = []

    private(set) var counts: [String: Int] = [:]
    private(set) var blobRequests = 0
    private(set) var maxBlobsAtOnce = 0
    private var blobsNow = 0
    private(set) var writeTimes: [TimeInterval] = []

    var client: GitHubClient { GitHubClient(transport: self, tokens: FakeGitHub.Tokens()) }
    private let prefix = "/repos/octo/MAIPA-G-data"

    func count(_ key: String) -> Int { lock.withLock { counts[key] ?? 0 } }
    func resetCounts() { lock.withLock { counts = [:] } }

    func stream(_ request: HTTPRequest) async throws -> HTTPStreamResponse { try await fake.stream(request) }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let path = request.url.path
        let isWrite = request.method != "GET" && request.method != "HEAD"
        let key = Self.kind(request.method, path: path, query: request.url.query, prefix: prefix)
        lock.withLock {
            counts[key, default: 0] += 1
            if isWrite { writeTimes.append(ProcessInfo.processInfo.systemUptime) }
        }
        if request.method == "GET", path.hasPrefix(prefix + "/git/trees/") {
            return listTree(String(path.dropFirst((prefix + "/git/trees/").count)), recursive: request.url.query?.contains("recursive") == true)
        }
        if request.method == "POST", path == prefix + "/git/blobs" { return try await blob(request) }
        if request.method == "POST", path == prefix + "/git/trees", let failure = lock.withLock({ () -> TreeFailure? in
            defer { failNextTree = nil }
            return failNextTree
        }) {
            switch failure {
            case .offline: throw HTTPError.transport("The Internet connection appears to be offline.", isOffline: true)
            case .refused: return Self.json(["message": "fixture refused the tree"], status: 422)
            case .rateLimited: return Self.secondaryLimit()
            }
        }
        if request.method == "PATCH", path == prefix + "/git/refs/heads/main", let drop = lock.withLock({ () -> Drop? in
            defer { dropNextRefUpdate = nil }
            return dropNextRefUpdate
        }) {
            if drop == .afterLanding { _ = try await fake.send(request) }
            throw HTTPError.transport("The network connection was lost.", isOffline: false)
        }
        return try await fake.send(request)
    }

    private func blob(_ request: HTTPRequest) async throws -> HTTPResponse {
        let (number, limited, shortWait) = lock.withLock { () -> (Int, Bool, Bool) in
            blobRequests += 1
            let wait = shortRetryAfterOnce
            shortRetryAfterOnce = false
            return (blobRequests, blobLimitAfter.map { blobRequests > $0 } ?? false, wait)
        }
        onBlob?(number)
        if limited { return Self.secondaryLimit() }
        if shortWait {
            return HTTPResponse(status: 429, headers: ["content-type": "application/json", "retry-after": "1"], body: Data(#"{"message":"You have exceeded a secondary rate limit."}"#.utf8))
        }
        lock.withLock {
            blobsNow += 1
            maxBlobsAtOnce = max(maxBlobsAtOnce, blobsNow)
        }
        defer { lock.withLock { blobsNow -= 1 } }
        if blobDelay > 0 { try await Task.sleep(nanoseconds: UInt64(blobDelay * 1_000_000_000)) }
        if let clock = watchedActivity, let progress = request.uploadProgress {
            let before = clock.secondsSinceLastActivity()
            progress(Int64(request.body?.count ?? 0))
            let after = clock.secondsSinceLastActivity()
            lock.withLock {
                quietBeforeProgress.append(before)
                quietAfterProgress.append(after)
            }
        }
        return try await fake.send(request)
    }

    static func secondaryLimit() -> HTTPResponse {
        HTTPResponse(status: 403, headers: ["content-type": "application/json", "retry-after": "120"], body: Data(#"{"message":"You have exceeded a secondary rate limit. Please wait a few minutes before you try again."}"#.utf8))
    }

    static func json(_ value: JSONValue, status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status, headers: ["content-type": "application/json"], body: Data(value.jsonString().utf8))
    }

    static func kind(_ method: String, path: String, query: String?, prefix: String) -> String {
        let rest = path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
        if rest.hasPrefix("/git/trees/") { return query?.contains("recursive") == true ? "GET tree recursive" : "GET tree" }
        if rest.hasPrefix("/git/commits/") { return "GET commit" }
        if rest == "/git/blobs" { return "POST blob" }
        if rest == "/git/trees" { return "POST tree" }
        if rest == "/git/commits" { return "POST commit" }
        if rest.hasPrefix("/git/refs/heads/") { return "PATCH ref" }
        return "\(method) \(rest)"
    }

    // Folders get made-up ids that name the real tree and the folder, so any folder can be listed.
    private static func folderID(tree: String, folder: String) -> String {
        "sub-\(tree)-" + Data(folder.utf8).map { String(format: "%02x", $0) }.joined()
    }

    private static func parse(_ id: String) -> (tree: String, folder: String) {
        guard id.hasPrefix("sub-") else { return (id, "") }
        let parts = id.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return (id, "") }
        var bytes: [UInt8] = []
        var hex = Substring(parts[2])
        while hex.count >= 2 {
            bytes.append(UInt8(hex.prefix(2), radix: 16) ?? 0)
            hex = hex.dropFirst(2)
        }
        return (String(parts[1]), String(decoding: bytes, as: UTF8.self))
    }

    private func listTree(_ id: String, recursive: Bool) -> HTTPResponse {
        let (named, folder) = Self.parse(id)
        let treeID = fake.commits[named]?.tree ?? named
        guard let flat = fake.trees[treeID] else { return Self.json(["message": "Not Found"], status: 404) }
        func entry(_ path: String, _ sha: String, folder isFolder: Bool) -> JSONValue {
            ["path": .string(path), "mode": .string(isFolder ? "040000" : "100644"), "type": .string(isFolder ? "tree" : "blob"), "sha": .string(sha)]
        }
        if recursive {
            var files = flat.filter { $0.key.hasPrefix(folder) }.sorted { $0.key < $1.key }.map { (String($0.key.dropFirst(folder.count)), $0.value) }
            let cut = folder.isEmpty ? truncateWholeListing : truncatedFolders.contains(folder)
            if cut { files = Array(files.prefix(files.count / 3)) }
            return Self.json(["sha": .string(id), "tree": .array(files.map { entry($0.0, $0.1, folder: false) }), "truncated": .bool(cut)])
        }
        var files: [(String, String)] = []
        var folders: Set<String> = []
        for (path, sha) in flat where path.hasPrefix(folder) {
            let rest = path.dropFirst(folder.count)
            if let slash = rest.firstIndex(of: "/") { folders.insert(String(rest[..<slash])) } else { files.append((String(rest), sha)) }
        }
        files.sort { $0.0 < $1.0 }
        let cut = truncatedFolderLevels.contains(folder)
        if cut { files = Array(files.prefix(files.count / 2)) }
        let entries = files.map { entry($0.0, $0.1, folder: false) }
            + folders.sorted().map { entry($0, Self.folderID(tree: treeID, folder: folder + $0 + "/"), folder: true) }
        return Self.json(["sha": .string(id), "tree": .array(entries), "truncated": .bool(cut)])
    }
}

/// A phone's data folder, its backup engine, and an unreliable GitHub.
struct SyncRig {
    let github = UnreliableGitHub()
    let root: URL
    let data: URL
    let stateURL: URL
    let sync: DataRepoSync
    let store: ChatStore

    init(writeSpacing: TimeInterval = 0) async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("maipag-reliable-\(UUID().uuidString)", isDirectory: true)
        data = root.appendingPathComponent("data", isDirectory: true)
        stateURL = root.appendingPathComponent("sync-state.json")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        github.fake.commitRemotely(["README.md": Data("# MAIPA-G-data\n".utf8)])
        sync = DataRepoSync(github: github.client, dataDirectory: data, stateURL: stateURL, writeSpacing: writeSpacing)
        store = ChatStore(dataDirectory: data)
        try await sync.ensureRepository(owner: "octo")
    }

    /// The same phone after MAIPA-G was closed and opened again.
    func reopened(writeSpacing: TimeInterval = 0) -> DataRepoSync {
        DataRepoSync(github: github.client, dataDirectory: data, stateURL: stateURL, writeSpacing: writeSpacing)
    }

    func write(_ bytes: Data, to path: String) throws {
        let url = data.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: url)
    }

    func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: data.appendingPathComponent(path).path) }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }

    static func attachment(_ index: Int) -> String { "attachments/\(String(format: "%04d", index))/file.txt" }
}

@Suite("Saving stays reliable")
struct SyncReliabilityTests {
    // MARK: 1. A file list GitHub cuts short is never read as deletions

    @Test func aTruncatedListingIsReadFolderByFolder() async throws {
        let rig = try await SyncRig()
        defer { rig.cleanUp() }
        var chats: [Chat] = []
        for index in 0..<3 {
            let chat = DataRepoSyncTests.chat("chat \(index)", updated: Date(timeIntervalSince1970: 1_000))
            try await rig.store.save(chat)
            chats.append(chat)
        }
        for index in 0..<4 { try rig.write(Data("picture \(index)".utf8), to: SyncRig.attachment(index)) }
        let first = try await rig.sync.sync()
        #expect(first.uploaded.count == 7)

        // Another phone edits a chat, so this one lists GitHub again, and the one-call list is cut short.
        var edited = chats[0]
        edited.title = "edited elsewhere"
        edited.updatedAt = Date(timeIntervalSince1970: 5_000)
        rig.github.fake.commitRemotely([ChatStore.relativePath(for: edited.id): try JSONCoding.encoder(pretty: true).encode(edited)])
        rig.github.truncateWholeListing = true
        rig.github.truncatedFolders = ["attachments/"]
        rig.github.resetCounts()

        let report = try await rig.sync.sync()
        #expect(report.downloaded == [ChatStore.relativePath(for: edited.id)])
        #expect(report.deletedHere.isEmpty && report.deletedThere.isEmpty)
        #expect(!report.remoteListingIncomplete)
        #expect(report.problems.isEmpty, "\(report.problems)")
        for chat in chats { #expect(rig.exists(ChatStore.relativePath(for: chat.id))) }
        for index in 0..<4 { #expect(rig.exists(SyncRig.attachment(index))) }
        #expect(await rig.store.load(edited.id)?.title == "edited elsewhere")
        // The root one level at a time, then each folder; a folder still too long, a level at a time.
        #expect(rig.github.count("GET tree") >= 2)
        #expect(rig.github.count("GET tree recursive") >= 3)
        #expect(await rig.sync.state.lastCommit != nil, "a complete list is trusted next time")
        #expect(await rig.sync.pendingPaths().isEmpty)
    }

    @Test func anIncompleteListingNeverDeletesEitherWay() async throws {
        let rig = try await SyncRig()
        defer { rig.cleanUp() }
        let keep = DataRepoSyncTests.chat("keep", updated: Date())
        let doomed = DataRepoSyncTests.chat("deleted on this phone", updated: Date())
        try await rig.store.save(keep)
        try await rig.store.save(doomed)
        let picture = SyncRig.attachment(1)
        try rig.write(Data("deleted on the other phone".utf8), to: picture)
        _ = try await rig.sync.sync()
        let doomedPath = ChatStore.relativePath(for: doomed.id)

        // This phone deletes a chat; another phone deletes the picture. GitHub's list can't be read
        // in full, even folder by folder.
        try FileManager.default.removeItem(at: rig.data.appendingPathComponent(doomedPath))
        rig.github.fake.commitRemotely([picture: nil])
        rig.github.truncateWholeListing = true
        rig.github.truncatedFolders = ["chats/", "attachments/"]
        rig.github.truncatedFolderLevels = ["chats/", "attachments/"]

        let blind = try await rig.sync.sync()
        #expect(blind.remoteListingIncomplete)
        #expect(blind.deletedHere.isEmpty && blind.deletedThere.isEmpty)
        #expect(rig.exists(picture), "not on the list is not deleted")
        #expect(rig.github.fake.remoteFile(doomedPath) != nil)
        #expect(await rig.sync.state.lastCommit == nil, "an incomplete list is listed again next time")
        #expect(blind.pendingPaths.contains(doomedPath))

        // Once the list can be read in full, both deletions go through.
        rig.github.truncateWholeListing = false
        rig.github.truncatedFolders = []
        rig.github.truncatedFolderLevels = []
        let seen = try await rig.sync.sync()
        #expect(seen.deletedThere == [doomedPath])
        #expect(seen.deletedHere == [picture])
        #expect(!rig.exists(picture))
        #expect(rig.github.fake.remoteFile(doomedPath) == nil)
        #expect(rig.exists(ChatStore.relativePath(for: keep.id)))
    }

    // MARK: 2. An interrupted pass keeps its progress

    @Test func aPassStoppedBeforeCommittingDoesNotSendTheSameFilesAgain() async throws {
        let rig = try await SyncRig()
        defer { rig.cleanUp() }
        for index in 0..<3 { try rig.write(Data("file \(index)".utf8), to: SyncRig.attachment(index)) }
        rig.github.failNextTree = .offline
        await #expect(throws: (any Error).self) { try await rig.sync.sync() }
        #expect(rig.github.blobRequests == 3)
        #expect(FileManager.default.fileExists(atPath: DataRepoSync.uploadedBlobsURL(for: rig.stateURL).path))

        // MAIPA-G is closed and opened again: the remembered blobs are committed, not sent again.
        let reopened = rig.reopened()
        let report = try await reopened.sync()
        #expect(report.uploaded.count == 3 && report.commit != nil)
        #expect(rig.github.blobRequests == 3)
        for index in 0..<3 { #expect(rig.github.fake.remoteFile(SyncRig.attachment(index)) == Data("file \(index)".utf8)) }
        #expect(!FileManager.default.fileExists(atPath: DataRepoSync.uploadedBlobsURL(for: rig.stateURL).path), "committed blobs leave the journal")
    }

    @Test func aRefusedTreeForgetsRememberedBlobs() async throws {
        let rig = try await SyncRig()
        defer { rig.cleanUp() }
        for index in 0..<2 { try rig.write(Data("file \(index)".utf8), to: SyncRig.attachment(index)) }
        rig.github.failNextTree = .refused
        await #expect(throws: GitHubAPIError.self) { try await rig.sync.sync() }
        #expect(!FileManager.default.fileExists(atPath: DataRepoSync.uploadedBlobsURL(for: rig.stateURL).path))
        let report = try await rig.sync.sync()
        #expect(report.uploaded.count == 2)
        #expect(rig.github.blobRequests == 4, "sent again, in case GitHub no longer had them")
    }

    @Test func aBigPassCommitsEvery25FilesAndStopsAt50() async throws {
        let rig = try await SyncRig()
        defer { rig.cleanUp() }
        #expect(await rig.sync.uploadFileLimit == 50)
        #expect(await rig.sync.commitEveryFiles == 25)
        for index in 0..<60 { try rig.write(Data("file \(index)".utf8), to: SyncRig.attachment(index)) }

        let first = try await rig.sync.sync()
        #expect(first.uploaded.count == 50)
        #expect(first.commitCount == 2 && rig.github.fake.savedCommits == 2)
        #expect(first.deferred.count == 10 && first.hasMoreToSave)
        #expect(first.pendingPaths.count == 10)
        let second = try await rig.sync.sync()
        #expect(second.uploaded.count == 10 && second.commitCount == 1 && !second.hasMoreToSave)
        for index in 0..<60 { #expect(rig.github.fake.remoteFile(SyncRig.attachment(index)) == Data("file \(index)".utf8)) }
        #expect(rig.github.blobRequests == 60)
    }

    @Test func aPassCommitsAfterItsTimeEvenWithFewFiles() async throws {
        let rig = try await SyncRig()
        defer { rig.cleanUp() }
        await rig.sync.setPassLimits(commitSeconds: 0)
        for index in 0..<9 { try rig.write(Data("file \(index)".utf8), to: SyncRig.attachment(index)) }
        let report = try await rig.sync.sync()
        // One file alone first, then groups of four: a commit after each group.
        #expect(report.uploaded.count == 9)
        #expect(report.commitCount == 3)
    }

    @Test func aCancelledPassKeepsTheCommitsItMadeAndTheBlobsItSent() async throws {
        let rig = try await SyncRig()
        defer { rig.cleanUp() }
        await rig.sync.setPassLimits(parallel: 1, commitEvery: 5)
        for index in 0..<30 { try rig.write(Data("file \(index)".utf8), to: SyncRig.attachment(index)) }
        let sync = rig.sync
        let pass = Task { try await sync.sync() }
        rig.github.onBlob = { number in if number == 12 { pass.cancel() } }
        await #expect(throws: (any Error).self) { try await pass.value }
        rig.github.onBlob = nil
        #expect(rig.github.fake.savedCommits == 2, "files 1 to 10 were committed in two pieces")
        for index in 0..<10 { #expect(rig.github.fake.remoteFile(SyncRig.attachment(index)) != nil) }

        let rest = try await rig.sync.sync()
        #expect(rest.uploaded.count == 20)
        #expect(rig.github.blobRequests == 30, "nothing was sent twice")
        for index in 0..<30 { #expect(rig.github.fake.remoteFile(SyncRig.attachment(index)) == Data("file \(index)".utf8)) }
    }

    @Test func aRateLimitPartWayCommitsWhatWentUpAndWaits() async throws {
        let rig = try await SyncRig()
        defer { rig.cleanUp() }
        await rig.sync.setPassLimits(parallel: 1)
        for index in 0..<8 { try rig.write(Data("file \(index)".utf8), to: SyncRig.attachment(index)) }
        rig.github.blobLimitAfter = 3
        let started = Date()
        let report = try await rig.sync.sync()
        #expect(report.uploaded.count == 3 && report.commit != nil)
        #expect(report.deferred.count == 5)
        #expect(!report.hasMoreToSave, "no straight-away pass while GitHub asked for a pause")
        let until = try #require(report.rateLimitedUntil)
        #expect(abs(until.timeIntervalSince(started) - 120) < 15, "GitHub's retry-after is kept")
        #expect(rig.github.blobRequests == 4, "stopped at the first refusal")
        #expect(Date().timeIntervalSince(started) < 10)

        rig.github.blobLimitAfter = nil
        let rest = try await rig.sync.sync()
        #expect(rest.uploaded.count == 5)
        #expect(rig.github.blobRequests == 9)
        for index in 0..<8 { #expect(rig.github.fake.remoteFile(SyncRig.attachment(index)) != nil) }
    }

    @Test func aRateLimitedCommitKeepsTheBlobsForTheNextPass() async throws {
        let rig = try await SyncRig()
        defer { rig.cleanUp() }
        for index in 0..<3 { try rig.write(Data("file \(index)".utf8), to: SyncRig.attachment(index)) }
        rig.github.failNextTree = .rateLimited
        let paused = try await rig.sync.sync()
        #expect(paused.commit == nil && paused.uploaded.isEmpty)
        #expect(paused.rateLimitedUntil != nil && paused.deferred.count == 3)
        #expect(paused.pendingPaths.count == 3)
        let resumed = try await rig.sync.sync()
        #expect(resumed.uploaded.count == 3)
        #expect(rig.github.blobRequests == 3)
    }

    // MARK: 3. Real progress, not a guess

    @Test func uploadProgressAndAnswersKeepTheWatchdogAwake() async throws {
        let rig = try await SyncRig()
        defer { rig.cleanUp() }
        rig.github.blobDelay = 0.4
        rig.github.watchedActivity = rig.sync.activity
        try rig.write(Data("slow".utf8), to: SyncRig.attachment(1))
        _ = try await rig.sync.sync()
        let before = try #require(rig.github.quietBeforeProgress.first)
        let after = try #require(rig.github.quietAfterProgress.first)
        #expect(before >= 0.3, "nothing pretends to be progress")
        #expect(after < 0.1, "sent bytes count as progress")
        #expect(rig.sync.activity.secondsSinceLastActivity() < 1, "GitHub's answers count as progress")
    }

    @Test func aPassAskedToFinishCommitsAndReturns() async throws {
        let rig = try await SyncRig()
        defer { rig.cleanUp() }
        for index in 0..<3 { try rig.write(Data("file \(index)".utf8), to: SyncRig.attachment(index)) }
        rig.sync.monitor.finish(within: 0)
        let hurried = try await rig.sync.sync()
        #expect(hurried.uploaded.isEmpty && hurried.deferred.count == 3 && hurried.problems.isEmpty)
        rig.sync.monitor.clearFinish()
        let normal = try await rig.sync.sync()
        #expect(normal.uploaded.count == 3)
        #expect(rig.sync.monitor.committedFiles == 3)
    }

    @Test func aDroppedConnectionOnTheBranchMoveIsRetried() async throws {
        for drop in [UnreliableGitHub.Drop.afterLanding, .beforeLanding] {
            let rig = try await SyncRig()
            defer { rig.cleanUp() }
            try rig.write(Data("file".utf8), to: SyncRig.attachment(1))
            rig.github.dropNextRefUpdate = drop
            let report = try await rig.sync.sync()
            #expect(report.uploaded == [SyncRig.attachment(1)], "\(drop)")
            #expect(rig.github.fake.head == report.commit, "\(drop)")
            #expect(rig.github.count("PATCH ref") == 2, "\(drop)")
            #expect(rig.github.blobRequests == 1 && rig.github.fake.savedCommits == 1, "no second pass for \(drop)")
        }
    }

    @Test func dropsAreTemporaryButNoConnectionIsOffline() {
        let lost = URLSessionTransport.transportError(URLError(.networkConnectionLost)) as? HTTPError
        #expect(lost?.isOffline == false)
        #expect(defaultRetryDelay(lost!) == 0)
        #expect(GitHubClient.writeRetryDelay(lost!) == 0)
        let offline = HTTPError.transport("The Internet connection appears to be offline.", isOffline: true)
        #expect(GitHubClient.writeRetryDelay(offline) == nil)
    }

    // MARK: 5. Rate limits as GitHub describes them

    @Test func retryAfterAndTheHourlyResetAreRead() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let secondary = GitHubAPIError(response: HTTPResponse(status: 403, headers: ["retry-after": "30"], body: Data(#"{"message":"You have exceeded a secondary rate limit."}"#.utf8)), now: now)
        #expect(secondary.isRateLimited && secondary.rateLimitResetsAt == nil)
        #expect(secondary.retryAt == now.addingTimeInterval(30))

        let reset = now.addingTimeInterval(1_200)
        let hourly = GitHubAPIError(response: HTTPResponse(status: 429, headers: ["x-ratelimit-remaining": "0", "x-ratelimit-reset": String(Int(reset.timeIntervalSince1970))], body: Data(#"{"message":"API rate limit exceeded"}"#.utf8)), now: now)
        #expect(hourly.isRateLimited && hourly.rateLimitResetsAt == reset && hourly.retryAt == reset)

        let both = GitHubAPIError(response: HTTPResponse(status: 403, headers: ["retry-after": "60", "x-ratelimit-remaining": "0", "x-ratelimit-reset": String(Int(reset.timeIntervalSince1970))], body: Data()), now: now)
        #expect(both.retryAt == reset, "never sooner than either")

        let plain = GitHubAPIError(response: HTTPResponse(status: 403, body: Data(#"{"message":"Resource not accessible by integration"}"#.utf8)), now: now)
        #expect(!plain.isRateLimited && plain.retryAt == nil)

        // A short wait is sat out; a long one, or a limit with no time, hands the pause back.
        #expect(GitHubClient.writeRetryDelay(GitHubAPIError(status: 403, message: "secondary rate limit", retryAt: Date().addingTimeInterval(5)))! > 3)
        #expect(GitHubClient.writeRetryDelay(GitHubAPIError(status: 403, message: "secondary rate limit", retryAt: Date().addingTimeInterval(120))) == nil)
        #expect(GitHubClient.writeRetryDelay(GitHubAPIError(status: 403, message: "You have exceeded a secondary rate limit")) == nil)
        #expect(GitHubClient.writeRetryDelay(GitHubAPIError(status: 502, message: "Bad gateway")) == 0)
    }

    @Test func aShortRetryAfterIsWaitedOutAndTheFileStillGoes() async throws {
        let rig = try await SyncRig()
        defer { rig.cleanUp() }
        try rig.write(Data("file".utf8), to: SyncRig.attachment(1))
        rig.github.shortRetryAfterOnce = true
        let started = Date()
        let report = try await rig.sync.sync()
        #expect(report.uploaded == [SyncRig.attachment(1)] && report.problems.isEmpty)
        #expect(Date().timeIntervalSince(started) >= 0.9, "not sent again before GitHub's time")
        #expect(rig.github.blobRequests == 2)
    }

    @Test func writesAreSpacedOutAndReadsAreNot() async throws {
        let pacer = WritePacer(spacing: 0.2)
        let started = ProcessInfo.processInfo.systemUptime
        for _ in 0..<4 { try await pacer.waitForTurn() }
        #expect(ProcessInfo.processInfo.systemUptime - started >= 0.55)
        #expect(DataRepoSync.defaultWriteSpacing == 1)

        let rig = try await SyncRig(writeSpacing: 0.15)
        defer { rig.cleanUp() }
        for index in 0..<5 { try rig.write(Data("file \(index)".utf8), to: SyncRig.attachment(index)) }
        _ = try await rig.sync.sync()
        let times = rig.github.writeTimes
        #expect(times.count == 8, "5 blobs, a tree, a commit and the branch move")
        for (earlier, later) in zip(times, times.dropFirst()) { #expect(later - earlier >= 0.13) }
    }

    // MARK: 6. Files go up a few at a time

    @Test func filesGoUpThreeOrFourAtATime() async throws {
        let rig = try await SyncRig()
        defer { rig.cleanUp() }
        rig.github.blobDelay = 0.2
        for index in 0..<9 { try rig.write(Data("file \(index)".utf8), to: SyncRig.attachment(index)) }
        let started = Date()
        let report = try await rig.sync.sync()
        #expect(report.uploaded.count == 9)
        #expect(rig.github.maxBlobsAtOnce >= 3 && rig.github.maxBlobsAtOnce <= 4)
        #expect(Date().timeIntervalSince(started) < 9 * 0.2)
    }

    // MARK: 7. Edited files of 1 to 20 MB are noticed

    @Test func anEditedMediumFileIsUploadedAgain() async throws {
        let rig = try await SyncRig()
        defer { rig.cleanUp() }
        let path = "media/run/clip.mov"
        let original = SaveEverythingTests.bytes(1_200_000)
        try rig.write(original, to: path)
        let first = try await rig.sync.sync()
        #expect(first.uploaded == [path])

        // Same size, new bytes, a later date.
        let edited = SaveEverythingTests.bytes(1_200_000)
        try rig.write(edited, to: path)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: rig.data.appendingPathComponent(path).path)
        let second = try await rig.sync.sync()
        #expect(second.uploaded == [path])
        #expect(rig.github.fake.remoteFile(path) == edited)

        // A different size too.
        let longer = SaveEverythingTests.bytes(1_500_000)
        try rig.write(longer, to: path)
        let third = try await rig.sync.sync()
        #expect(third.uploaded == [path])
        #expect(rig.github.fake.remoteFile(path) == longer)
        #expect(await rig.sync.pendingPaths().isEmpty)
    }

    @Test func aBigFileWithNoRecordIsNotReadAgainOnOpen() async throws {
        let rig = try await SyncRig()
        defer { rig.cleanUp() }
        let path = "attachments/big/photo.heic"
        try rig.write(SaveEverythingTests.bytes(1_100_000), to: path)
        _ = try await rig.sync.sync()
        try FileManager.default.removeItem(at: rig.root.appendingPathComponent("blob-hash-cache.json"))
        let reopened = rig.reopened()
        let report = try await reopened.sync()
        #expect(!report.changedAnything && report.problems.isEmpty)
        #expect(report.pendingPaths.isEmpty)
    }

    @Test func theHashCacheIsWrittenOnlyWhenItChanged() async throws {
        let rig = try await SyncRig()
        defer { rig.cleanUp() }
        let cache = rig.root.appendingPathComponent("blob-hash-cache.json")
        try rig.write(Data("one".utf8), to: SyncRig.attachment(1))
        _ = try await rig.sync.sync()
        #expect(FileManager.default.fileExists(atPath: cache.path))
        try FileManager.default.removeItem(at: cache)
        _ = try await rig.sync.sync()
        #expect(!FileManager.default.fileExists(atPath: cache.path), "nothing new, nothing written")
        try rig.write(Data("two".utf8), to: SyncRig.attachment(2))
        _ = try await rig.sync.sync()
        #expect(FileManager.default.fileExists(atPath: cache.path))
    }

    @Test func thePassSaysWhatIsStillPendingWithoutASecondScan() async throws {
        let rig = try await SyncRig()
        defer { rig.cleanUp() }
        await rig.sync.setPassLimits(files: 2)
        for index in 0..<5 { try rig.write(Data("file \(index)".utf8), to: SyncRig.attachment(index)) }
        let chat = DataRepoSyncTests.chat("from the other phone", updated: Date())
        rig.github.fake.commitRemotely([ChatStore.relativePath(for: chat.id): try JSONCoding.encoder(pretty: true).encode(chat)])
        let report = try await rig.sync.sync()
        #expect(report.downloaded == [ChatStore.relativePath(for: chat.id)])
        let rescanned = await rig.sync.pendingPaths()
        #expect(report.pendingPaths == rescanned)
        #expect(report.pendingPaths.count == 3)
    }

    // MARK: 8. Fewer calls per save

    @Test func aSaveOnAnUnmovedBranchAsksForNoTree() async throws {
        let rig = try await SyncRig()
        defer { rig.cleanUp() }
        try rig.write(Data("one".utf8), to: SyncRig.attachment(1))
        _ = try await rig.sync.sync()
        #expect(rig.github.count("GET commit") == 1, "one look at the branch's commit to list it, none to commit")
        rig.github.resetCounts()
        try rig.write(Data("two".utf8), to: SyncRig.attachment(2))
        let report = try await rig.sync.sync()
        #expect(report.uploaded == [SyncRig.attachment(2)])
        #expect(rig.github.count("GET commit") == 0)
        #expect(rig.github.count("GET tree") + rig.github.count("GET tree recursive") == 0)
        #expect(await rig.sync.state.lastTree != nil)
    }

    // MARK: 9. A chat still streaming is saved once its reply ends

    @Test func aStreamingChatWaitsForItsTurnToEnd() async throws {
        let rig = try await SyncRig()
        defer { rig.cleanUp() }
        var chat = DataRepoSyncTests.chat("streaming", updated: Date())
        let path = ChatStore.relativePath(for: chat.id)
        let other = SyncRig.attachment(1)
        try await rig.store.save(chat)
        try rig.write(Data("made by the reply".utf8), to: other)

        let during = try await rig.sync.sync(holding: [path])
        #expect(during.uploaded == [other], "everything else keeps saving")
        #expect(rig.github.fake.remoteFile(path) == nil)
        #expect(during.pendingPaths.contains(path))
        chat.messages.append(.user("more"))
        try await rig.store.save(chat)
        let still = try await rig.sync.sync(holding: [path])
        #expect(still.uploaded.isEmpty && still.commit == nil)

        let ended = try await rig.sync.sync()
        #expect(ended.uploaded == [path])
        #expect(rig.github.fake.savedCommits == 2)
        #expect(ended.pendingPaths.isEmpty)
    }

    @Test func aVeryLongReplyIsStillSavedNowAndThen() async throws {
        let rig = try await SyncRig()
        defer { rig.cleanUp() }
        await rig.sync.setPassLimits(holdSeconds: 0.3)
        let chat = DataRepoSyncTests.chat("long reply", updated: Date())
        let path = ChatStore.relativePath(for: chat.id)
        try await rig.store.save(chat)
        let held = try await rig.sync.sync(holding: [path])
        #expect(held.uploaded.isEmpty)
        try await Task.sleep(nanoseconds: 350_000_000)
        let saved = try await rig.sync.sync(holding: [path])
        #expect(saved.uploaded == [path])
    }
}
