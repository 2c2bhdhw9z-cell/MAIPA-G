import Foundation

public enum StagedChange: Sendable, Hashable {
    case write(path: String, data: Data, existed: Bool)
    case delete(path: String, previous: Data)

    public var path: String {
        switch self { case .write(let path, _, _), .delete(let path, _): return path }
    }
}

/// A safe mutable overlay on one immutable repository snapshot.
public actor ChangeWorkspace {
    public nonisolated let base: RepoWorkspace
    private var changes: [String: StagedChange] = [:]

    public init(base: RepoWorkspace) { self.base = base }

    public func stagedDiff() async -> String {
        guard !changes.isEmpty else { return "No staged changes." }
        var sections: [String] = []
        for change in changes.values.sorted(by: { $0.path < $1.path }) {
            switch change {
            case .delete(let path, let previous):
                let old = TextFileCodec.decode(previous)?.text ?? "[binary content]"
                sections.append("--- a/\(path)\n+++ /dev/null\n" + old.split(separator: "\n", omittingEmptySubsequences: false).map { "-" + $0 }.joined(separator: "\n"))
            case .write(let path, let data, let existed):
                let new = TextFileCodec.decode(data)?.text ?? "[binary content]"
                let old: String
                if existed {
                    let read = try? await base.readDecodedFile(path)
                    if case .text(let document, _)? = read { old = document.text }
                    else { old = "" }
                } else {
                    old = ""
                }
                let removed = old.split(separator: "\n", omittingEmptySubsequences: false).map { "-" + $0 }
                let added = new.split(separator: "\n", omittingEmptySubsequences: false).map { "+" + $0 }
                sections.append("--- \(existed ? "a/\(path)" : "/dev/null")\n+++ b/\(path)\n" + (removed + added).joined(separator: "\n"))
            }
        }
        return String(sections.joined(separator: "\n\n").prefix(200_000))
    }

    public func stagedChanges() -> [StagedChange] { changes.values.sorted { $0.path < $1.path } }
    public func discardAll() { changes.removeAll() }

    public func read(_ rawPath: String) async throws -> FileRead {
        let path = try Self.safe(rawPath)
        switch try await readDecoded(path) {
        case .text(let document, let bytes): return .text(document.text, bytes: bytes)
        case .binary(let bytes): return .binary(bytes: bytes)
        case .tooLarge(let bytes): return .tooLarge(bytes: bytes)
        case .folder: return .folder
        case .symlink(let target): return .symlink(target: target)
        case .missing(let suggestions): return .missing(suggestions: suggestions)
        }
    }

    public func create(path rawPath: String, text: String, buildSetupApproved: Bool = false) async throws {
        let path = try Self.safe(rawPath)
        if Self.isBuildSetup(path), !buildSetupApproved { throw ChangeWorkspaceError.buildSetupApprovalRequired(path) }
        switch try await readBase(path) {
        case .missing:
            let data = Data(text.utf8)
            guard TextFileCodec.decode(data) != nil else { throw ChangeWorkspaceError.notText(path) }
            changes[path] = .write(path: path, data: data, existed: false)
        default: throw ChangeWorkspaceError.alreadyExists(path)
        }
    }

    public func edit(path rawPath: String, text: String, buildSetupApproved: Bool = false) async throws {
        let path = try Self.safe(rawPath)
        if Self.isBuildSetup(path), !buildSetupApproved { throw ChangeWorkspaceError.buildSetupApprovalRequired(path) }
        let document: TextFileCodec.Document
        switch try await readBase(path) {
        case .text(let decoded, _): document = decoded
        case .missing: throw ChangeWorkspaceError.missing(path)
        case .folder: throw ChangeWorkspaceError.notText(path)
        case .binary, .tooLarge, .symlink: throw ChangeWorkspaceError.notText(path)
        }
        let data = TextFileCodec.encode(text, preserving: document)
        guard TextFileCodec.decode(data) != nil else { throw ChangeWorkspaceError.notText(path) }
        changes[path] = .write(path: path, data: data, existed: true)
    }

    public func delete(path rawPath: String, approved: Bool = false) async throws {
        let path = try Self.safe(rawPath)
        guard approved else { throw ChangeWorkspaceError.deletionApprovalRequired(path) }
        if Self.isBuildSetup(path), !approved { throw ChangeWorkspaceError.buildSetupApprovalRequired(path) }
        let previous: Data
        switch try await readDecoded(path) {
        case .text(let document, _): previous = document.data
        case .missing: throw ChangeWorkspaceError.missing(path)
        default: throw ChangeWorkspaceError.notText(path)
        }
        changes[path] = .delete(path: path, previous: previous)
    }

    func baseBlob(for path: String) async throws -> String? {
        try await base.tree().entries.first { $0.path == path && $0.isFile }?.sha
    }

    private func readDecoded(_ path: String) async throws -> DecodedFileRead {
        if let change = changes[path] {
            switch change {
            case .write(_, let data, _):
                guard let document = TextFileCodec.decode(data) else { return .binary(bytes: data.count) }
                return .text(document, bytes: data.count)
            case .delete:
                return .missing(suggestions: [])
            }
        }
        return try await readBase(path)
    }

    private func readBase(_ path: String) async throws -> DecodedFileRead {
        try await base.readDecodedFile(path)
    }

    public static func safe(_ rawPath: String) throws -> String {
        let path = RepoWorkspace.normalize(rawPath)
        guard SnapshotStore.isSafeRelativePath(path) else { throw ChangeWorkspaceError.unsafePath(rawPath) }
        return path
    }

    public static func isBuildSetup(_ path: String) -> Bool {
        let lower = path.lowercased()
        let exact: Set<String> = ["package.swift", "package.resolved", "podfile", "cartfile", "project.yml", "project.yaml", "makefile", "dockerfile"]
        return exact.contains(lower) || lower.hasPrefix(".github/workflows/") || lower.hasSuffix(".xcodeproj/project.pbxproj") || lower.hasSuffix("package.json")
    }
}

public enum ChangeWorkspaceError: Error, Sendable, Equatable, CustomStringConvertible {
    case unsafePath(String), missing(String), alreadyExists(String), notText(String)
    case deletionApprovalRequired(String), buildSetupApprovalRequired(String), noChanges
    case staleHead(expected: String, actual: String?)

    public var description: String {
        switch self {
        case .unsafePath(let path): return "Unsafe path: \(path)"
        case .missing(let path): return "There is no file \(path)."
        case .alreadyExists(let path): return "\(path) already exists. Use edit_file."
        case .notText(let path): return "\(path) is not an editable text file."
        case .deletionApprovalRequired(let path): return "Deleting \(path) needs the person's approval."
        case .buildSetupApprovalRequired(let path): return "Changing build setup in \(path) needs the person's approval."
        case .noChanges: return "There are no staged changes."
        case .staleHead(let expected, let actual): return "The branch moved after MAIPA-G's save (expected \(expected.prefix(7)), now \(actual?.prefix(7) ?? "missing")). Undo stopped without overwriting it."
        }
    }
}
