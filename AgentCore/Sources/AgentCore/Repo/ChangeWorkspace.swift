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

    public func stagedChanges() -> [StagedChange] { changes.values.sorted { $0.path < $1.path } }
    public func discardAll() { changes.removeAll() }

    public func read(_ rawPath: String) async throws -> FileRead {
        let path = try Self.safe(rawPath)
        if let change = changes[path] {
            switch change {
            case .write(_, let data, _): return .text(String(decoding: data, as: UTF8.self), bytes: data.count)
            case .delete: return .missing(suggestions: [])
            }
        }
        return try await base.readFile(path)
    }

    public func create(path rawPath: String, text: String, buildSetupApproved: Bool = false) async throws {
        let path = try Self.safe(rawPath)
        if Self.isBuildSetup(path), !buildSetupApproved { throw ChangeWorkspaceError.buildSetupApprovalRequired(path) }
        switch try await readBase(path) {
        case .missing: changes[path] = .write(path: path, data: Data(text.utf8), existed: false)
        default: throw ChangeWorkspaceError.alreadyExists(path)
        }
    }

    public func edit(path rawPath: String, text: String, buildSetupApproved: Bool = false) async throws {
        let path = try Self.safe(rawPath)
        if Self.isBuildSetup(path), !buildSetupApproved { throw ChangeWorkspaceError.buildSetupApprovalRequired(path) }
        let existed: Bool
        switch try await readBase(path) {
        case .text: existed = true
        case .missing: throw ChangeWorkspaceError.missing(path)
        case .folder: throw ChangeWorkspaceError.notText(path)
        case .binary, .tooLarge, .symlink: throw ChangeWorkspaceError.notText(path)
        }
        changes[path] = .write(path: path, data: Data(text.utf8), existed: existed)
    }

    public func delete(path rawPath: String, approved: Bool = false) async throws {
        let path = try Self.safe(rawPath)
        guard approved else { throw ChangeWorkspaceError.deletionApprovalRequired(path) }
        if Self.isBuildSetup(path), !approved { throw ChangeWorkspaceError.buildSetupApprovalRequired(path) }
        let previous: Data
        switch try await read(path) {
        case .text(let text, _): previous = Data(text.utf8)
        case .missing: throw ChangeWorkspaceError.missing(path)
        default: throw ChangeWorkspaceError.notText(path)
        }
        changes[path] = .delete(path: path, previous: previous)
    }

    func baseBlob(for path: String) async throws -> String? {
        try await base.tree().entries.first { $0.path == path && $0.isFile }?.sha
    }

    private func readBase(_ path: String) async throws -> FileRead { try await base.readFile(path) }

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
