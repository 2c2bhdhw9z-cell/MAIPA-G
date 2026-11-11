import Foundation
import Testing
import ZIPFoundation
@testable import AgentCore

/// 11 November 2026: the AI pasted a GitHub artifact link (which needs a GitHub sign-in to open)
/// instead of handing over the .deb. Now it gives the file itself, as a card in the chat.
@Suite("Handing over files in the chat")
struct SendFileTests {
    static func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("maipa-g-send-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func zip(_ files: [String: Data], at url: URL) throws {
        let archive = try Archive(url: url, accessMode: .create)
        for (name, data) in files.sorted(by: { $0.key < $1.key }) {
            try archive.addEntry(with: name, type: .file, uncompressedSize: Int64(data.count)) { position, size in
                data.subdata(in: Int(position)..<Int(position) + size)
            }
        }
    }

    final class ArtifactTransport: HTTPTransport, @unchecked Sendable {
        let zip: Data
        init(zip: Data) { self.zip = zip }
        func send(_ request: HTTPRequest) async throws -> HTTPResponse {
            HTTPResponse(status: 200, headers: [:], body: zip)
        }
        func stream(_ request: HTTPRequest) async throws -> HTTPStreamResponse {
            HTTPStreamResponse(status: 500, headers: [:], body: AsyncThrowingStream { $0.finish() })
        }
    }

    struct Tokens: GitHubTokenProvider {
        func installationToken() async throws -> String { "t" }
        func userToken() async throws -> String { "t" }
    }

    @Test("A GitHub artifact zip gives the file asked for, the only file, or the only .ipa")
    func picksFromAnArtifact() async throws {
        let work = try Self.folder()
        defer { try? FileManager.default.removeItem(at: work) }
        let zipURL = work.appendingPathComponent("a.zip")
        try Self.zip(["Vellum.deb": Data("deb-bytes".utf8), "Vellum.dylib": Data("dylib-bytes".utf8)], at: zipURL)
        let transport = ArtifactTransport(zip: try Data(contentsOf: zipURL))
        let store = AttachmentStore(dataDirectory: work.appendingPathComponent("data", isDirectory: true))
        let tool = SendFileTool(github: GitHubClient(transport: transport, tokens: Tokens()), transport: transport, computer: nil, store: store, workDirectory: work)
        let output = try await tool.run(arguments: ["url": "https://api.github.com/repos/me/vellum/actions/artifacts/1/zip", "pick": "Vellum.deb"]) { _ in }
        let file = try #require(output.generatedImages.first)
        #expect(file.attachment.name == "Vellum.deb")
        #expect(file.isFile && !file.isVideo)
        #expect(file.attachment.path.hasPrefix("media/"))
        #expect(try await store.data(for: file.attachment) == Data("deb-bytes".utf8))
        // Two files and no pick: the zip itself.
        let whole = try await tool.run(arguments: ["url": "https://api.github.com/repos/me/vellum/actions/artifacts/1/zip"]) { _ in }
        #expect(whole.generatedImages.first?.attachment.name == "artifact.zip")
        await #expect(throws: ToolInputError.self) {
            _ = try await tool.run(arguments: ["url": "https://api.github.com/repos/me/vellum/actions/artifacts/1/zip", "pick": "Missing.ipa"]) { _ in }
        }
    }

    @Test("A file on the computer comes into the chat", .enabled(if: ComputerTransferTests.onLinux))
    func bringsAFileFromTheComputer() async throws {
        let work = try Self.folder()
        defer { try? FileManager.default.removeItem(at: work) }
        let home = work.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent("build"), withIntermediateDirectories: true)
        try Data("ipa-bytes".utf8).write(to: home.appendingPathComponent("build/App.ipa"))
        let store = AttachmentStore(dataDirectory: work.appendingPathComponent("data", isDirectory: true))
        let tool = SendFileTool(github: nil, transport: URLSessionTransport(), computer: ComputerControl.local(machine: "test", home: home), store: store, workDirectory: work)
        let output = try await tool.run(arguments: ["computer_path": "~/build/App.ipa"]) { _ in }
        let file = try #require(output.generatedImages.first)
        #expect(file.attachment.name == "App.ipa")
        #expect(try await store.data(for: file.attachment) == Data("ipa-bytes".utf8))
    }
}

@Suite("Tokens on the computer")
struct HandedOverTokenTests {
    @Test("After GitHub refuses the token, the computer waits for the phone's next one instead of failing")
    func waitsForTheNextToken() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("maipa-g-tokens-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let refresh = folder.appendingPathComponent("token-refresh.json.gz")
        let tokens = HandedOverTokens(token: "old", refreshFile: refresh, waitForFresh: 30)
        #expect(try await tokens.installationToken() == "old")
        await tokens.forgetInstallationToken()
        Task {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            try VMCoding.pack(VMSecrets(openRouterKey: nil, githubToken: "new")).write(to: refresh)
        }
        #expect(try await tokens.installationToken() == "new")
        #expect(!FileManager.default.fileExists(atPath: refresh.path))
    }
}
