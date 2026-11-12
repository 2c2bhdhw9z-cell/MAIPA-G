import Foundation
import Testing
@testable import AgentCore

/// The owner's build 173 reports (11 November 2026): pictures failing on a gateway that was down,
/// the AI never saving memories, and "Lost contact with your computer".
@Suite("Build 174 fixes")
struct Build174Tests {
    #if os(Linux)
    static let onLinux = true
    #else
    static let onLinux = false
    #endif

    @Test("A command that starts a server in the background finishes when its shell does", .enabled(if: onLinux))
    func backgroundServerDoesNotHoldTheCommand() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("maipa-g-bg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let control = ComputerControl.local(machine: "test", home: home)
        let started = Date()
        let output = try await control.run("(setsid nohup sleep 25 > /dev/null 2>&1 &) ; (sleep 25 &) ; echo started")
        #expect(output.contains("started"))
        #expect(Date().timeIntervalSince(started) < 10)
    }

    @Test("A gateway's 'temporarily unable … retry shortly' 500 counts as a service that's down for a moment")
    func temporaryGatewayErrorIsTemporary() {
        let body = Data(#"{"error":{"code":"500","message":"The service is temporarily unable to serve this request. Please retry shortly."}}"#.utf8)
        let error = OpenRouterAPIError(status: 500, body: body, headers: [:], providerName: "TeamoRouter")
        #expect(error.kind == .providerFailed)
        #expect(error.isTemporary)
        let broken = OpenRouterAPIError(status: 400, body: Data(#"{"error":{"code":"400","message":"bad prompt"}}"#.utf8), headers: [:], providerName: "TeamoRouter")
        #expect(!broken.isTemporary)
    }

    @Test("The picture models are ranked best first, the same family on another provider next")
    func rankedPictureModels() {
        func model(_ id: String, created: Double) -> ModelInfo {
            ModelInfo(id: id, name: id, promptPrice: 0.000001, completionPrice: 0.00001, inputModalities: ["image", "text"],
                      outputModalities: ["image", "text"], created: Date(timeIntervalSince1970: created))
        }
        let models = [
            model("oneprovider::flux-2-pro", created: 3),
            model("teamorouter::gemini-3-pro-image", created: 2),
            model("oneprovider::gemini-3-pro-image", created: 1),
        ]
        let ranked = ImageModelChooser.ranked(for: .edit, among: models).map(\.id)
        #expect(ranked.prefix(2) == ["teamorouter::gemini-3-pro-image", "oneprovider::gemini-3-pro-image"])
        #expect(ImageModelChooser.best(for: .edit, among: models)?.id == ranked.first)
    }

    @Test("A follow-up edit is sent with the changes asked for before it")
    func followUpEditCarriesEarlierRequests() {
        let prompt = QuickPictureRequest.edit("No, I said purple gold.").prompt(earlier: ["Now a purple gold."])
        #expect(prompt.hasPrefix("Change this picture: No, I said purple gold."))
        #expect(prompt.contains("\"Now a purple gold.\""))
        #expect(!prompt.contains(".."))
        #expect(QuickPictureRequest.edit("make it red").prompt == QuickPictureRequest.edit("make it red").prompt(earlier: []))
    }

    @Test("The AI is told to save preferences and corrections to memories, even before there are any")
    func memoryInstructionsAreProactive() {
        let prompt = SystemPrompt.make(userLogin: nil, repo: nil)
        #expect(prompt.contains("call `add_memory` in that same turn without asking"))
        #expect(AddMemoryTool(store: ProductStore<MemoryRecord>(dataDirectory: FileManager.default.temporaryDirectory, folder: "m")).spec.function.description.contains("without asking"))
    }

    @Test("Memories the AI saves on the computer come back with the reply's state")
    func memoriesTravelBack() throws {
        let saved = MemoryRecord(text: "No pull requests.", source: .ai)
        let state = VMTurnState(id: "r", seq: 1, phase: .running, turn: AssistantTurn(), memories: [saved])
        let decoded = try VMCoding.unpack(VMTurnState.self, from: VMCoding.pack(state))
        #expect(decoded.memories?.map(\.text) == ["No pull requests."])
        #expect(!VMTurnRunner.promptNote(machine: "m", hasConnectors: true).contains("memories"))
    }
}

extension Build174Tests {
    @Test("A command's output, exit code and slow steps all still arrive", .enabled(if: onLinux))
    func commandsStillRunToTheEnd() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("maipa-g-cmd-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let control = ComputerControl.local(machine: "test", home: home)
        let output = try await control.run("echo one; sleep 1.5; echo \"two $0\"; case x in x) echo three ;; esac # trailing comment")
        #expect(output.contains("one") && output.contains("two") && output.contains("three"))
        let failed = try await control.run("echo before; exit 3")
        #expect(failed.contains("before") && failed.contains("(exit code 3)"), "\(failed)")
    }
}
