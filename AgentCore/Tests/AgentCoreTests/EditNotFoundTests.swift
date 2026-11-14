import Foundation
import Testing
@testable import AgentCore

/// Owner, 14 November 2026: the AI read and edited the same two files over and over. Each missed
/// edit was told only "Call read_file first", so it read a few lines, retyped them from memory,
/// missed again. A miss now shows the file's real lines where it was aiming.
@Suite("A missed edit shows the real lines")
struct EditNotFoundTests {
    static let file = (1...300).map { "line \($0) of the test file" }.joined(separator: "\n")
        .replacingOccurrences(of: "line 268 of the test file", with: "    assert.equal(RegisteredRoot.name, \"KorgOverlay\");")
        .replacingOccurrences(of: "line 269 of the test file", with: "    const overlayElement = RegisteredRoot({});")
        .replacingOccurrences(of: "line 270 of the test file", with: "    assert.equal(overlayElement.type.name, \"Overlay\");")

    @Test("Text retyped a little wrong gets the closest lines, numbered, with no read needed")
    func showsClosestLines() {
        let remembered = """
        assert.equal(RegisteredRoot.name, "KorgOverlay");
        const overlayElement = RegisteredRoot();
        assert.equal(overlayElement.type.name, "Overlay");
        """
        let message = ChangeWorkspace.notFoundMessage(path: "tests/plugins.test.mjs", source: Self.file, oldText: remembered)
        #expect(message.contains("closest part of the file is lines 268–270"))
        #expect(message.contains("   269\t    const overlayElement = RegisteredRoot({});"))
        #expect(message.contains("   265\t") && message.contains("   273\t"))
        #expect(!message.contains("   264\t") && !message.contains("   274\t"))
        #expect(message.contains("Don't read the file again"))
        #expect(!message.contains("Call read_file"))
    }

    @Test("Lines all retyped differently are found by their first words")
    func anchorsOnLongLine() {
        let remembered = "    assert.equal(RegisteredRoot.name, 'KorgOverlay')"
        let message = ChangeWorkspace.notFoundMessage(path: "t.mjs", source: Self.file, oldText: remembered)
        #expect(message.contains("   268\t    assert.equal(RegisteredRoot.name, \"KorgOverlay\");"))
    }

    @Test("Nothing like it in the file says so instead of guessing")
    func nothingSimilar() {
        let message = ChangeWorkspace.notFoundMessage(path: "t.mjs", source: Self.file, oldText: "zzz qqq")
        #expect(message.contains("No part of it looks like old_text"))
        #expect(message.contains("it has 300 lines now"))
    }

    @Test("The edit tool's miss carries the real lines")
    func throughTheTool() async throws {
        let (_, changes, root) = try ToolParityTests.workspace(["tests/plugins.test.mjs": Data(Self.file.utf8)])
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            _ = try await changes.replace(path: "tests/plugins.test.mjs", oldText: "const overlayElement = RegisteredRoot();", newText: "x")
            Issue.record("A text that isn't there must not be replaced")
        } catch let error as ToolInputError {
            #expect(error.message.contains("   269\t    const overlayElement = RegisteredRoot({});"))
        }
    }
}
