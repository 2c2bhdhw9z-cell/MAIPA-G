import Foundation
import Testing
import ZIPFoundation
@testable import AgentCore

@Suite("Data export")
struct DataExportTests {
    @Test func archiveContainsMirroredFilesAndManifestWithoutAbsolutePaths() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("maipag-export-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let data = root.appendingPathComponent("data", isDirectory: true)
        try FileManager.default.createDirectory(at: data.appendingPathComponent("chats"), withIntermediateDirectories: true)
        try Data("chat".utf8).write(to: data.appendingPathComponent("chats/one.json"))
        try Data([1, 2, 3]).write(to: data.appendingPathComponent("picture.png"))
        let output = root.appendingPathComponent("export.zip")

        try DataExport.makeArchive(dataDirectory: data, destination: output, date: Date(timeIntervalSince1970: 1_800_000_000))
        let archive = try #require(Archive(url: output, accessMode: .read))
        let names = archive.map(\.path)
        #expect(names.contains { $0.hasSuffix("/data/chats/one.json") })
        #expect(names.contains { $0.hasSuffix("/data/picture.png") })
        #expect(names.contains { $0.hasSuffix("/manifest.json") })
        #expect(names.allSatisfy { !$0.hasPrefix("/") && !$0.split(separator: "/").contains("..") })
    }
}
