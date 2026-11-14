import Foundation
import Testing
@testable import AgentCore

@Suite("A reply on the computer reaches MAIPA-G-data")
struct ComputerDataRepoTests {
    // Tests that hand a tool the real local computer run on Linux only (they hang on GitHub's Mac).
    #if os(Linux)
    static let onLinux = true
    #else
    static let onLinux = false
    #endif
    static let repo = RepoRef(owner: "octo", name: "MAIPA-G-data")

    static func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("maipag-cdr-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("A big made file goes up once by its SHA-256 and comes down to the phone checked")
    func bigFileRelaysAndArrives() async throws {
        let github = FakeGitHub()
        let dataRepo = ComputerDataRepo(github: github.client, repo: Self.repo, branch: "main")
        let root = try Self.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data((0..<(3 * 1024 * 1024)).map { UInt8($0 % 251) })
        let file = root.appendingPathComponent("App.ipa")
        try bytes.write(to: file)

        let relay = try await dataRepo.relay(file)
        #expect(relay.size == bytes.count && relay.sha256 == Hashing.sha256Hex(bytes))
        #expect(github.asset(named: relay.sha256 + ".bin") == bytes)
        let again = try await dataRepo.relay(file)
        #expect(again.assetID == relay.assetID && github.assetUploads == 1, "the same file is never uploaded twice")

        let phone = root.appendingPathComponent("phone", isDirectory: true)
        var result = GeneratedImageResult(attachment: AttachmentReference(name: "App.ipa", mimeType: "application/octet-stream", kind: .file, path: "media/abc/App.ipa", bytes: bytes.count), prompt: "App.ipa", model: "file", aspectRatio: "", quality: "")
        result.relay = relay
        try await VMMedia.bring(result, runID: "turn-1", computer: nil, github: github.client, into: phone)
        #expect(try Data(contentsOf: phone.appendingPathComponent("media/abc/App.ipa")) == bytes)

        // A file that doesn't match its checksum is refused, with the reason.
        var damaged = result
        damaged.attachment.path = "media/def/App.ipa"
        damaged.relay?.sha256 = String(repeating: "0", count: 64)
        do {
            try await VMMedia.bring(damaged, runID: "turn-1", computer: nil, github: github.client, into: phone)
            Issue.record("A damaged file should be refused")
        } catch let error as ToolInputError {
            #expect(error.message.contains("damaged"))
        }
        #expect(!FileManager.default.fileExists(atPath: phone.appendingPathComponent("media/def/App.ipa").path))
    }

    @Test("send_file on the computer copies the file there and relays a big one; a small one comes the usual way", .enabled(if: onLinux))
    func sendFileOnTheComputer() async throws {
        let root = try Self.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent("build"), withIntermediateDirectories: true)
        let big = Data(repeating: 7, count: ComputerDataRepo.relayThreshold + 10)
        try big.write(to: home.appendingPathComponent("build/App.ipa"))
        try Data("small".utf8).write(to: home.appendingPathComponent("build/notes.txt"))
        let relayed = SendFileRecorder()
        let tool = SendFileTool(
            github: nil, transport: URLSessionTransport(), computer: ComputerControl.local(machine: "test", home: home),
            store: AttachmentStore(dataDirectory: root.appendingPathComponent("data")), workDirectory: root,
            localHome: home,
            relay: { file in
                relayed.add(file.lastPathComponent)
                return RelayedFile(repo: Self.repo, assetID: 5, sha256: try Hashing.sha256Hex(fileAt: file), size: big.count)
            }
        )
        let sent = try await tool.run(arguments: ["computer_path": "~/build/App.ipa"]) { _ in }
        #expect(sent.generatedImages.first?.relay?.assetID == 5)
        #expect(sent.forModel.contains("MAIPA-G-data"))
        let small = try await tool.run(arguments: ["computer_path": "build/notes.txt"]) { _ in }
        #expect(small.generatedImages.first?.relay == nil)
        #expect(relayed.names == ["App.ipa"])
        await #expect(throws: ToolInputError.self) { _ = try await tool.run(arguments: ["computer_path": "build/missing.ipa"]) { _ in } }
    }

    @Test("The chat is saved from the computer only while the phone is away, and never brought back after it was deleted")
    func runningChatIsSavedWhileThePhoneIsAway() async throws {
        let github = FakeGitHub()
        let root = try Self.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        var chat = Chat()
        chat.messages = [.user("Build the app"), ChatMessage(body: .assistant(AssistantTurn()))]
        let path = ChatStore.relativePath(for: chat.id)
        github.commitRemotely([path: try JSONCoding.encoder(pretty: true).encode(chat)])
        let dataRepo = ComputerDataRepo(github: github.client, repo: Self.repo, branch: "main")
        let saver = RunningChatSaver(dataRepo: dataRepo, folder: root, awayAfter: 60, every: 30, startedAt: Date(timeIntervalSinceNow: -100))
        var turn = AssistantTurn()
        var step = AssistantStep()
        step.text = "Working on it"
        turn.steps = [step]

        // The phone looked a moment ago: it saves the chat itself.
        try Data().write(to: root.appendingPathComponent(RunningChatSaver.phoneSeenFile))
        await saver.step(chat: chat, turn: turn, runID: "turn-abc")
        #expect(github.savedCommits == 0)

        // The phone has been away for two minutes.
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -120)], ofItemAtPath: root.appendingPathComponent(RunningChatSaver.phoneSeenFile).path)
        await saver.step(chat: chat, turn: turn, runID: "turn-abc")
        #expect(github.savedCommits == 1)
        let saved = try JSONCoding.decoder().decode(Chat.self, from: try #require(github.remoteFile(path)))
        #expect(saved.lastAssistantTurn?.steps.first?.text == "Working on it")
        #expect(saved.computerRunID == "turn-abc", "a phone that opens it follows the reply instead of running it again")
        // Not again until there's more and it's time.
        await saver.step(chat: chat, turn: turn, runID: "turn-abc")
        #expect(github.savedCommits == 1)
        turn.status = .done
        await saver.step(chat: chat, turn: turn, runID: "turn-abc", final: true)
        let finished = try JSONCoding.decoder().decode(Chat.self, from: try #require(github.remoteFile(path)))
        #expect(finished.lastAssistantTurn?.status == .done && finished.computerRunID == nil)

        // Deleted on the phone: it stays deleted.
        github.commitRemotely([path: nil])
        let commits = github.savedCommits
        await saver.step(chat: chat, turn: turn, runID: "turn-abc", final: true)
        #expect(github.remoteFile(path) == nil && github.savedCommits == commits)
    }
}

private final class SendFileRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [String] = []
    func add(_ name: String) { lock.withLock { list.append(name) } }
    var names: [String] { lock.withLock { list } }
}
