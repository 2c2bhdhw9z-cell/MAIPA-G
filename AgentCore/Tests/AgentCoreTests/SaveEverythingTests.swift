import Foundation
import Testing
@testable import AgentCore

@Suite("Everything saves, big files included")
struct SaveEverythingTests {
    /// Two phones sharing one fake MAIPA-G-data, with a tiny "big file" size so tests stay fast.
    struct TwoPhones {
        let github = FakeGitHub()
        let root: URL
        let first: URL
        let second: URL
        let phoneOne: DataRepoSync
        let phoneTwo: DataRepoSync

        init(threshold: Int = 1_024) async throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("maipag-save-\(UUID().uuidString)", isDirectory: true)
            first = root.appendingPathComponent("one/data", isDirectory: true)
            second = root.appendingPathComponent("two/data", isDirectory: true)
            for folder in [first, second] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
            github.commitRemotely(["README.md": Data("# MAIPA-G-data\n".utf8)])
            phoneOne = DataRepoSync(github: github.client, dataDirectory: first, stateURL: root.appendingPathComponent("one/state.json"), largeFileThreshold: threshold)
            phoneTwo = DataRepoSync(github: github.client, dataDirectory: second, stateURL: root.appendingPathComponent("two/state.json"), largeFileThreshold: threshold)
            try await phoneOne.ensureRepository(owner: "octo")
            try await phoneTwo.ensureRepository(owner: "octo")
        }

        func write(_ data: Data, to path: String, in folder: URL) throws {
            let url = folder.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
    }

    static func bytes(_ count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: 0...255, using: &generator) })
    }

    @Test func bigAttachmentsSaveToTheFilesReleaseAndComeBackOnAnotherPhone() async throws {
        let phones = try await TwoPhones()
        defer { try? FileManager.default.removeItem(at: phones.root) }
        let big = Self.bytes(50_000), small = Data("small picture".utf8)
        let bigPath = "attachments/08bdc952-3703-442d-9b63-1e896c453926/Continuum-235.ipa"
        let pointerPath = bigPath + DataRepoSync.pointerSuffix
        try phones.write(big, to: bigPath, in: phones.first)
        try phones.write(small, to: "attachments/aaaa/photo.png", in: phones.first)

        let saved = try await phones.phoneOne.sync()
        #expect(saved.problems.isEmpty, "\(saved.problems)")
        #expect(Set(saved.uploaded) == [pointerPath, "attachments/aaaa/photo.png"])
        #expect(phones.github.remoteFile(bigPath) == nil, "the big file itself stays out of Git")
        let pointer = try #require(phones.github.remoteFile(pointerPath).flatMap(LargeFilePointer.parse))
        #expect(pointer.path == bigPath && pointer.size == big.count && pointer.sha256 == Hashing.sha256Hex(big))
        #expect(phones.github.asset(named: Hashing.sha256Hex(big) + ".bin") == big)
        #expect(phones.github.remoteFile("attachments/aaaa/photo.png") == small)

        // Nothing changed: no commit and no second upload.
        let idle = try await phones.phoneOne.sync()
        #expect(!idle.changedAnything && idle.problems.isEmpty && phones.github.assetUploads == 1)
        #expect(await phones.phoneOne.pendingPaths().isEmpty)

        // A second phone gets the real file back, checked, and no pointer file on disk.
        let restored = try await phones.phoneTwo.sync()
        #expect(restored.problems.isEmpty, "\(restored.problems)")
        #expect(Set(restored.downloaded) == [pointerPath, "attachments/aaaa/photo.png"])
        #expect(try Data(contentsOf: phones.second.appendingPathComponent(bigPath)) == big)
        #expect(!FileManager.default.fileExists(atPath: phones.second.appendingPathComponent(pointerPath).path))
        let settled = try await phones.phoneTwo.sync()
        #expect(!settled.changedAnything && settled.problems.isEmpty)

        // Deleting it on one phone deletes it on the other.
        try FileManager.default.removeItem(at: phones.first.appendingPathComponent(bigPath))
        let deleted = try await phones.phoneOne.sync()
        #expect(deleted.deletedThere == [pointerPath])
        let gone = try await phones.phoneTwo.sync()
        #expect(gone.deletedHere == [pointerPath])
        #expect(!FileManager.default.fileExists(atPath: phones.second.appendingPathComponent(bigPath).path))
    }

    @Test func aBigFileAlreadyInGitMovesOnlyOnceItsReleaseCopyIsSafe() async throws {
        let phones = try await TwoPhones()
        defer { try? FileManager.default.removeItem(at: phones.root) }
        let big = Self.bytes(4_000)
        let path = "media/run/picture.png"
        // Saved by an older build, when big files still went into Git.
        try phones.write(big, to: path, in: phones.first)
        phones.github.commitRemotely([path: big])
        let older = DataRepoSync(github: phones.github.client, dataDirectory: phones.first, stateURL: phones.root.appendingPathComponent("one/state.json"), largeFileThreshold: 1 << 30)
        _ = try await older.sync()

        // This build, on the same phone: the release refuses the upload, so the Git copy stays.
        let newer = DataRepoSync(github: phones.github.client, dataDirectory: phones.first, stateURL: phones.root.appendingPathComponent("one/state.json"), largeFileThreshold: 1_024)
        phones.github.failAssetUploads = true
        let refused = try await newer.sync()
        #expect(!refused.problems.isEmpty)
        #expect(phones.github.remoteFile(path) == big, "never delete the only saved copy")

        phones.github.failAssetUploads = false
        let moved = try await newer.sync()
        #expect(moved.problems.isEmpty, "\(moved.problems)")
        #expect(phones.github.remoteFile(path) == nil && phones.github.remoteFile(path + DataRepoSync.pointerSuffix) != nil)
        #expect(phones.github.asset(named: Hashing.sha256Hex(big) + ".bin") == big)
        #expect(try Data(contentsOf: phones.first.appendingPathComponent(path)) == big, "the phone keeps its file")
    }

    @Test func filesThatVanishMidSaveAndBriefGitHubFailuresAreNotProblems() async throws {
        let phones = try await TwoPhones()
        defer { try? FileManager.default.removeItem(at: phones.root) }
        let store = ChatStore(dataDirectory: phones.first)
        var keep = Chat(title: "keep")
        keep.messages = [.user("hi")]
        var vanish = Chat(title: "vanish")
        vanish.messages = [.user("bye")]
        try await store.save(keep)
        try await store.save(vanish)
        let paths = [ChatStore.relativePath(for: keep.id), ChatStore.relativePath(for: vanish.id)].sorted()
        // The phone deletes the second chat while the first is being saved, and GitHub has one
        // brief hiccup.
        let doomed = phones.first.appendingPathComponent(paths[1])
        phones.github.beforeNextBlob = { try? FileManager.default.removeItem(at: doomed) }
        phones.github.temporaryBlobFailures = 1

        let report = try await phones.phoneOne.sync()
        #expect(report.problems.isEmpty, "\(report.problems)")
        #expect(report.uploaded == [paths[0]])
        #expect(phones.github.remoteFile(paths[0]) != nil && phones.github.remoteFile(paths[1]) == nil)
        let next = try await phones.phoneOne.sync()
        #expect(next.problems.isEmpty && !next.changedAnything)
    }

    @Test func errorsSayWhatHappenedInsteadOfIOSPlaceholder() {
        #expect(HTTPError.transport("The request timed out.", isOffline: false).localizedDescription == "The request timed out.")
        #expect(GitHubAPIError(status: 403, message: "Resource not accessible by integration").localizedDescription == "GitHub 403: Resource not accessible by integration")
        #expect(ComputerControl.Failure.noCommandTool.localizedDescription.contains("no command tool"))
        #expect(DataRepoSync.Failure.repoNotVisible.localizedDescription.contains("isn't allowed"))
        enum Unnamed: Error { case brokenThing }
        let fallback = ErrorExplainer.describe(Unnamed.brokenThing)
        #expect(!ErrorExplainer.isPlaceholder(fallback.cause) && fallback.cause.contains("brokenThing"))
        let transport = ErrorExplainer.describe(HTTPError.transport("The network connection was lost.", isOffline: false))
        #expect(transport.cause.contains("The network connection was lost."))
        // Actions minutes: GitHub's real 403 type gets the Plan permission steps.
        let minutes = GitHubActionsBilling.explain(GitHubAPIError(status: 403, message: "Resource not accessible by integration"))
        #expect(minutes.contains("Plan") && minutes.contains("Read-only"))
    }
}
