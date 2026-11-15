import Foundation
import Testing
import ZIPFoundation
@testable import AgentCore

/// GitHub's artifact address answers with a redirect to storage that needs no token, as the real one does.
private final class ArtifactGitHub: HTTPTransport, @unchecked Sendable {
    let zip: Data
    private let lock = NSLock()
    private var seen: [HTTPRequest] = []
    init(zip: Data) { self.zip = zip }
    var requests: [HTTPRequest] { lock.withLock { seen } }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        lock.withLock { seen.append(request) }
        if request.url.path == "/repos/octo/korg/actions/artifacts/77/zip" {
            return HTTPResponse(status: 302, headers: ["Location": "https://storage.example/artifact.zip"])
        }
        return HTTPResponse(status: 404)
    }

    func stream(_ request: HTTPRequest) async throws -> HTTPStreamResponse {
        lock.withLock { seen.append(request) }
        guard request.url.host == "storage.example", request.headers["Authorization"] == nil else {
            return HTTPStreamResponse(status: 403, headers: [:], body: AsyncThrowingStream { $0.finish() })
        }
        let data = zip
        return HTTPStreamResponse(status: 200, headers: [:], body: AsyncThrowingStream { $0.yield(data); $0.finish() })
    }
}

private struct Tokens: GitHubTokenProvider {
    func installationToken() async throws -> String { "ghs_token" }
    func userToken() async throws -> String { "user" }
}

@Suite("GitHub downloads onto the computer, like gh run download")
struct GitHubDownloadTests {
    static func zip(_ entries: [String: String], at url: URL) throws -> Data {
        let archive = try #require(Archive(url: url, accessMode: .create))
        for (path, text) in entries.sorted(by: { $0.key < $1.key }) {
            let data = Data(text.utf8)
            try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count), provider: { position, size in
                data.subdata(in: Int(position)..<Int(position) + size)
            })
        }
        return try Data(contentsOf: url)
    }

    @Test("An Actions artifact comes down with MAIPA-G's sign-in and is unpacked where asked, and a zip can't write outside it")
    func artifactIsDownloadedAndUnpacked() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("maipag-download-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let zip = try Self.zip(["KorgLoader.dylib": "loader bytes", "logs/build.txt": "ok", "../escape.txt": "no"], at: home.appendingPathComponent("made.zip"))
        let transport = ArtifactGitHub(zip: zip)
        let tool = DownloadFromGitHubTool(github: GitHubClient(transport: transport, tokens: Tokens()), home: home)
        let output = try await tool.run(arguments: ["url": "https://api.github.com/repos/octo/korg/actions/artifacts/77/zip", "folder": "~/downloads/loader"]) { _ in }
        #expect(output.forModel.contains("unpacked 2 files into ~/downloads/loader"))
        #expect(output.forModel.contains("~/downloads/loader/KorgLoader.dylib"))
        #expect(try String(contentsOf: home.appendingPathComponent("downloads/loader/KorgLoader.dylib"), encoding: .utf8) == "loader bytes")
        #expect(try String(contentsOf: home.appendingPathComponent("downloads/loader/logs/build.txt"), encoding: .utf8) == "ok")
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent("downloads/escape.txt").path))
        // The token went to GitHub only; the storage address got none.
        let first = try #require(transport.requests.first)
        #expect(first.url.host == "api.github.com" && first.headers["Authorization"] != nil)
        #expect(transport.requests.last?.url.host == "storage.example")
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: home.appendingPathComponent(".maipa-g/downloads").path)) ?? []
        #expect(leftovers.isEmpty, "the download's scratch copy is removed")
    }

    @Test("Other hosts and folders outside home are refused; a release file keeps its name")
    func refusalsAndNames() async throws {
        let home = FileManager.default.temporaryDirectory
        let tool = DownloadFromGitHubTool(github: GitHubClient(transport: ArtifactGitHub(zip: Data()), tokens: Tokens()), home: home)
        await #expect(throws: ToolInputError.self) { _ = try await tool.run(arguments: ["url": "https://example.com/a.zip"]) { _ in } }
        await #expect(throws: ToolInputError.self) { _ = try await tool.run(arguments: ["url": "https://api.github.com/repos/octo/korg/actions/artifacts/77/zip", "folder": "../etc"]) { _ in } }
        let release = try #require(URL(string: "https://github.com/octo/korg/releases/download/v1/Korg.ipa"))
        #expect(DownloadFromGitHubTool.fileName(for: release, apiURL: "https://api.github.com/repos/octo/korg/releases/assets/5") == "Korg.ipa")
        let artifact = try #require(URL(string: "https://api.github.com/repos/octo/korg/actions/artifacts/77/zip"))
        #expect(DownloadFromGitHubTool.fileName(for: artifact, apiURL: artifact.absoluteString) == "artifact-77.zip")
    }
}
