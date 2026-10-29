import Foundation
import Testing
@testable import AgentCore

/// Real downloads from GitHub. Off by default so the CI checks never depend on the network;
/// run with MAIPAG_NETWORK_TESTS=1 to try a real repo end to end.
@Suite("Network", .enabled(if: ProcessInfo.processInfo.environment["MAIPAG_NETWORK_TESTS"] == "1"))
struct NetworkTests {
    @Test func readsAPublicWebPageSafely() async throws {
        let page = try await WebPageReader(transport: URLSessionTransport()).read(URL(string: "https://example.com")!)
        #expect(page.text.localizedCaseInsensitiveContains("example domain"))
        #expect(page.url.host == "example.com")
    }

    @Test func unpacksAndSearchesARealRepo() async throws {
        let repo = ProcessInfo.processInfo.environment["MAIPAG_TEST_REPO"] ?? "2c2bhdhw9z-cell/Continuum-"
        let ref = ProcessInfo.processInfo.environment["MAIPAG_TEST_REF"] ?? "master"
        let transport = URLSessionTransport()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("maipag-net-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = root.appendingPathComponent("repo.tar.gz")

        let started = Date()
        let response = try await transport.download(HTTPRequest(url: URL(string: "https://codeload.github.com/\(repo)/tar.gz/refs/heads/\(ref)")!), to: archive)
        #expect(response.isSuccess)
        let downloaded = Date()

        let files = root.appendingPathComponent("files", isDirectory: true)
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        var unpacker = SnapshotUnpacker(filesDirectory: files)
        var tar = TarReader()
        let inflater = try GzipInflater()
        let handle = try FileHandle(forReadingFrom: archive)
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            try inflater.feed(chunk) { try tar.feed($0, into: &unpacker) }
        }
        try handle.close()
        let unpacked = Date()

        let manifest = SnapshotManifest(formatVersion: 1, repo: RepoRef(fullName: repo)!, commit: unpacker.commitComment ?? "unknown", createdAt: Date(), files: unpacker.files.sorted { $0.path < $1.path })
        let snapshot = RepoSnapshot(directory: root, manifest: manifest)
        let result = try await CodeSearch.run(SearchQuery(pattern: "func ", maxResults: 50), in: snapshot)
        let searched = Date()

        let size = (try? FileManager.default.attributesOfItem(atPath: archive.path)[.size] as? Int) ?? 0
        print("""
        repo \(repo)@\(ref): \(size / 1024) KB download in \(String(format: "%.1f", downloaded.timeIntervalSince(started))) s,
        \(manifest.files.count) entries (\(manifest.files.filter { $0.kind == .text }.count) text, \(manifest.storedBytes / 1024) KB) unpacked in \(String(format: "%.2f", unpacked.timeIntervalSince(downloaded))) s,
        search: \(result.filesMatched) files matched of \(result.filesSearched) in \(String(format: "%.2f", searched.timeIntervalSince(unpacked))) s, commit \(manifest.commit)
        """)
        #expect(tar.isDone)
        #expect(unpacker.commitComment?.count == 40)
        #expect(!result.matches.isEmpty)
    }
}
