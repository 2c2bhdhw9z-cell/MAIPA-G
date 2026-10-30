import Foundation
import Testing
@testable import AgentCore

@Suite("Format-preserving repository edits")
struct TextFileCodecTests {
    @Test func preservesCRLFAndFinalNewline() throws {
        let original = Data("one\r\ntwo\r\n".utf8)
        let document = try #require(TextFileCodec.decode(original))

        #expect(document.text == "one\ntwo\n")
        #expect(TextFileCodec.encode("ONE\ntwo\n", preserving: document) == Data("ONE\r\ntwo\r\n".utf8))
    }

    @Test func preservesNoFinalNewline() throws {
        let original = Data("one\r\ntwo".utf8)
        let document = try #require(TextFileCodec.decode(original))

        #expect(TextFileCodec.encode("one\nTWO\n", preserving: document) == Data("one\r\nTWO".utf8))
    }

    @Test func preservesUTF8ByteOrderMark() throws {
        let original = Data([0xef, 0xbb, 0xbf]) + Data("hello\n".utf8)
        let document = try #require(TextFileCodec.decode(original))
        let encoded = TextFileCodec.encode("changed\n", preserving: document)

        #expect(encoded == Data([0xef, 0xbb, 0xbf]) + Data("changed\n".utf8))
    }

    @Test(arguments: [true, false])
    func preservesUTF16ByteOrderAndLineEndings(littleEndian: Bool) throws {
        let original = Self.utf16("alpha\r\nbeta\r\n", littleEndian: littleEndian)
        let document = try #require(TextFileCodec.decode(original))
        let encoded = TextFileCodec.encode("alpha\nBETA\n", preserving: document)

        #expect(encoded == Self.utf16("alpha\r\nBETA\r\n", littleEndian: littleEndian))
    }

    @Test func mixedLineEndingsStayWithUnchangedLines() throws {
        let original = Data("alpha\r\nbeta\ngamma\r".utf8)
        let document = try #require(TextFileCodec.decode(original))
        let encoded = TextFileCodec.encode("alpha\ninserted\nbeta\ngamma\n", preserving: document)

        #expect(encoded == Data("alpha\r\ninserted\r\nbeta\ngamma\r".utf8))
    }

    @Test func invalidAndBinaryLookingBytesAreRejected() {
        #expect(TextFileCodec.decode(Data([0xff, 0x61, 0x62])) == nil)
        #expect(TextFileCodec.decode(Data([0x50, 0x4b, 0x03, 0x04, 0x01, 0x02])) == nil)
        #expect(TextFileCodec.decode(Data([0x00, 0x61])) == nil)
        #expect(TextFileCodec.decode(Data([0xff, 0xfe, 0x00, 0x00, 0x61, 0x00, 0x00, 0x00])) == nil)
    }

    @Test func workspaceStagesOriginalEncodingAndRefusesBinary() async throws {
        let github = FakeGitHub()
        let utf16File = Self.utf16("old\r\n", littleEndian: true)
        let binary = Data([0x50, 0x4b, 0x03, 0x04, 0x01, 0x02])
        github.commitRemotely(["windows.txt": utf16File, "archive.bin": binary])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("maipag-codec-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = RepoWorkspace(
            repo: RepoRef(owner: "octo", name: "MAIPA-G-data"),
            branch: "main",
            commit: try #require(github.head),
            github: github.client,
            store: SnapshotStore(root: root)
        )
        let changes = ChangeWorkspace(base: workspace)

        try await changes.edit(path: "windows.txt", text: "new\n")
        let staged = await changes.stagedChanges()
        guard case .write(_, let data, _) = try #require(staged.first) else {
            Issue.record("Expected a staged write")
            return
        }
        #expect(data == Self.utf16("new\r\n", littleEndian: true))

        await #expect(throws: ChangeWorkspaceError.self) {
            try await changes.edit(path: "archive.bin", text: "not safe")
        }
        #expect(await changes.stagedChanges().count == 1)
    }

    private static func utf16(_ text: String, littleEndian: Bool) -> Data {
        var data = Data(littleEndian ? [0xff, 0xfe] : [0xfe, 0xff])
        for unit in text.utf16 {
            if littleEndian {
                data.append(UInt8(truncatingIfNeeded: unit))
                data.append(UInt8(truncatingIfNeeded: unit >> 8))
            } else {
                data.append(UInt8(truncatingIfNeeded: unit >> 8))
                data.append(UInt8(truncatingIfNeeded: unit))
            }
        }
        return data
    }
}
