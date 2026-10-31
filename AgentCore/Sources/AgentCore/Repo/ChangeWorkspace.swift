import Foundation

public enum StagedChange: Sendable, Hashable {
    case write(path: String, data: Data, existed: Bool)
    case delete(path: String, previous: Data)

    public var path: String {
        switch self { case .write(let path, _, _), .delete(let path, _): return path }
    }
}

private final class LockedBaseWorkspace: @unchecked Sendable {
    private let lock = NSLock()
    private var current: RepoWorkspace

    init(_ initial: RepoWorkspace) {
        self.current = initial
    }

    var value: RepoWorkspace {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func set(_ next: RepoWorkspace) {
        lock.lock()
        current = next
        lock.unlock()
    }
}

/// A safe mutable overlay on one repository snapshot.
public actor ChangeWorkspace {
    private nonisolated let baseHolder: LockedBaseWorkspace
    public nonisolated var base: RepoWorkspace { baseHolder.value }
    private var changes: [String: StagedChange] = [:]

    public init(base: RepoWorkspace) {
        self.baseHolder = LockedBaseWorkspace(base)
    }

    /// Advances the underlying commit/branch after `GitHubChangeService.save` pushes a commit so
    /// subsequent edits and saves in the same turn operate cleanly on top of the newly saved commit.
    public func advanceBase(toCommit newCommit: String, branch newBranch: String? = nil) {
        let updated = base.advancing(toCommit: newCommit, branch: newBranch)
        baseHolder.set(updated)
    }

    /// Carries unsaved staged edits onto a newer commit snapshot when the branch advances between turns.
    public func rebased(onto newBase: RepoWorkspace) async -> ChangeWorkspace {
        let next = ChangeWorkspace(base: newBase)
        for (_, item) in changes {
            switch item {
            case .write(let path, let data, _):
                let existedInNew: Bool
                if let decoded = try? await newBase.readDecodedFile(path) {
                    if case .missing = decoded { existedInNew = false }
                    else { existedInNew = true }
                } else {
                    existedInNew = false
                }
                await next.putStaged(.write(path: path, data: data, existed: existedInNew))
            case .delete(let path, let previous):
                if let decoded = try? await newBase.readDecodedFile(path) {
                    if case .missing = decoded { continue }
                }
                await next.putStaged(.delete(path: path, previous: previous))
            }
        }
        return next
    }

    private func putStaged(_ change: StagedChange) {
        changes[change.path] = change
    }

    public func hasStagedChanges() -> Bool {
        !changes.isEmpty
    }

    public func stagedDiff() async -> String {
        guard !changes.isEmpty else { return "No staged changes." }
        var sections: [String] = []
        for change in changes.values.sorted(by: { $0.path < $1.path }) {
            switch change {
            case .delete(let path, let previous):
                guard let oldDoc = TextFileCodec.decode(previous) else {
                    sections.append("--- a/\(path)\n+++ /dev/null\nBinary file a/\(path) deleted")
                    continue
                }
                if let patch = UnifiedDiffBuilder.filePatch(oldPath: "a/\(path)", newPath: "/dev/null", oldText: oldDoc.text, newText: "") {
                    sections.append(patch)
                }
            case .write(let path, let data, let existed):
                guard let newDoc = TextFileCodec.decode(data) else {
                    sections.append("--- \(existed ? "a/\(path)" : "/dev/null")\n+++ b/\(path)\nBinary file b/\(path) changed")
                    continue
                }
                let oldText: String
                if existed {
                    let read = try? await base.readDecodedFile(path)
                    if case .text(let document, _)? = read { oldText = document.text }
                    else { oldText = "" }
                } else {
                    oldText = ""
                }
                if let patch = UnifiedDiffBuilder.filePatch(
                    oldPath: existed ? "a/\(path)" : "/dev/null",
                    newPath: "b/\(path)",
                    oldText: oldText,
                    newText: newDoc.text
                ) {
                    sections.append(patch)
                }
            }
        }
        guard !sections.isEmpty else { return "No staged changes." }
        return String(sections.joined(separator: "\n\n").prefix(200_000))
    }

    public func stagedChanges() -> [StagedChange] { changes.values.sorted { $0.path < $1.path } }
    public func discardAll() { changes.removeAll() }

    public func stagedData(for rawPath: String) -> Data? {
        let normalized = RepoWorkspace.normalize(rawPath)
        guard let change = changes[normalized] else { return nil }
        switch change {
        case .write(_, let data, _): return data
        case .delete: return nil
        }
    }

    public func readRawBytes(_ rawPath: String, maxBytes: Int = 5 * 1024 * 1024) async throws -> Data? {
        let path = try Self.safe(rawPath)
        if let change = changes[path] {
            switch change {
            case .write(_, let data, _):
                return data.count <= maxBytes ? data : nil
            case .delete:
                return nil
            }
        }
        return try await base.readRawBytes(path, maxBytes: maxBytes)
    }

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

    public func mergedTree() async throws -> GitTree {
        let baseTree = try await base.tree()
        guard !changes.isEmpty else { return baseTree }
        var byPath: [String: GitTreeEntry] = [:]
        for entry in baseTree.entries {
            byPath[entry.path] = entry
        }
        for change in changes.values {
            switch change {
            case .delete(let path, _):
                byPath.removeValue(forKey: path)
            case .write(let path, let data, _):
                let sha = byPath[path]?.sha ?? ""
                byPath[path] = GitTreeEntry(path: path, mode: "100644", type: "blob", sha: sha, size: data.count)
                var parts = path.split(separator: "/").dropLast()
                while !parts.isEmpty {
                    let folder = parts.joined(separator: "/")
                    if byPath[folder] == nil {
                        byPath[folder] = GitTreeEntry(path: folder, mode: "040000", type: "tree", sha: "")
                    }
                    parts = parts.dropLast()
                }
            }
        }
        let sorted = byPath.values.sorted { $0.path < $1.path }
        return GitTree(sha: baseTree.sha, entries: sorted, truncated: baseTree.truncated)
    }

    public func create(path rawPath: String, text: String, buildSetupApproved: Bool = false) async throws {
        let path = try Self.safe(rawPath)
        if Self.isBuildSetup(path), !buildSetupApproved { throw ChangeWorkspaceError.buildSetupApprovalRequired(path) }
        switch try await readDecoded(path) {
        case .missing:
            let data = Data(text.utf8)
            guard TextFileCodec.decode(data) != nil else { throw ChangeWorkspaceError.notText(path) }
            let existedInBase: Bool
            if case .missing = try await readBase(path) { existedInBase = false }
            else { existedInBase = true }
            changes[path] = .write(path: path, data: data, existed: existedInBase)
        default: throw ChangeWorkspaceError.alreadyExists(path)
        }
    }

    public func edit(path rawPath: String, text: String, buildSetupApproved: Bool = false) async throws {
        let path = try Self.safe(rawPath)
        if Self.isBuildSetup(path), !buildSetupApproved { throw ChangeWorkspaceError.buildSetupApprovalRequired(path) }
        let document: TextFileCodec.Document
        switch try await readDecoded(path) {
        case .text(let decoded, _): document = decoded
        case .missing: throw ChangeWorkspaceError.missing(path)
        case .folder: throw ChangeWorkspaceError.notText(path)
        case .binary, .tooLarge, .symlink: throw ChangeWorkspaceError.notText(path)
        }
        let existedInBase: Bool
        if case .write(_, _, let prevExisted)? = changes[path] {
            existedInBase = prevExisted
        } else {
            existedInBase = true
        }
        let data = TextFileCodec.encode(text, preserving: document)
        guard TextFileCodec.decode(data) != nil else { throw ChangeWorkspaceError.notText(path) }
        changes[path] = .write(path: path, data: data, existed: existedInBase)
    }

    /// Surgical search-and-replace inside `rawPath`, returning `(replacements, snippetDiff)`.
    public func replace(
        path rawPath: String,
        oldText rawOld: String,
        newText rawNew: String,
        replaceAll: Bool = false,
        buildSetupApproved: Bool = false
    ) async throws -> (count: Int, diffPreview: String) {
        let path = try Self.safe(rawPath)
        if Self.isBuildSetup(path), !buildSetupApproved { throw ChangeWorkspaceError.buildSetupApprovalRequired(path) }
        let document: TextFileCodec.Document
        switch try await readDecoded(path) {
        case .text(let decoded, _): document = decoded
        case .missing: throw ChangeWorkspaceError.missing(path)
        case .folder, .binary, .tooLarge, .symlink: throw ChangeWorkspaceError.notText(path)
        }
        let normalizedSource = document.text.replacingOccurrences(of: "\r\n", with: "\n")
        let oldNorm = rawOld.replacingOccurrences(of: "\r\n", with: "\n")
        let newNorm = rawNew.replacingOccurrences(of: "\r\n", with: "\n")
        guard !oldNorm.isEmpty else {
            throw ToolInputError("\"old_text\" cannot be empty. Use create_file for a new file or append_file to add to the end.")
        }

        var exactRanges: [Range<String.Index>] = []
        var searchStart = normalizedSource.startIndex
        while searchStart < normalizedSource.endIndex,
              let range = normalizedSource.range(of: oldNorm, range: searchStart..<normalizedSource.endIndex) {
            exactRanges.append(range)
            searchStart = range.upperBound
        }

        let updatedText: String
        let replacedCount: Int

        if !exactRanges.isEmpty {
            if exactRanges.count > 1 && !replaceAll {
                throw ToolInputError("\"old_text\" matched \(exactRanges.count) places in \(path). Include a few surrounding lines so it matches only one place, or pass replace_all: true.")
            }
            if replaceAll {
                updatedText = normalizedSource.replacingOccurrences(of: oldNorm, with: newNorm)
                replacedCount = exactRanges.count
            } else {
                var copy = normalizedSource
                copy.replaceSubrange(exactRanges[0], with: newNorm)
                updatedText = copy
                replacedCount = 1
            }
        } else if let fuzzy = Self.fuzzyUniqueLineReplacement(source: normalizedSource, oldText: oldNorm, newText: newNorm) {
            updatedText = fuzzy
            replacedCount = 1
        } else {
            throw ToolInputError("\"old_text\" was not found in \(path). Call read_file on \(path) first to get the exact current lines.")
        }

        let existedInBase: Bool
        if case .write(_, _, let prevExisted)? = changes[path] {
            existedInBase = prevExisted
        } else {
            existedInBase = true
        }
        let data = TextFileCodec.encode(updatedText, preserving: document)
        guard TextFileCodec.decode(data) != nil else { throw ChangeWorkspaceError.notText(path) }
        changes[path] = .write(path: path, data: data, existed: existedInBase)
        let preview = UnifiedDiffBuilder.filePatch(oldPath: "a/\(path)", newPath: "b/\(path)", oldText: normalizedSource, newText: updatedText) ?? "Updated \(path)"
        return (replacedCount, String(preview.prefix(12_000)))
    }

    /// Appends UTF-8 text to the end of an existing (or optionally newly created) file without requiring a full-file rewrite.
    public func append(
        path rawPath: String,
        text: String,
        createIfMissing: Bool = false,
        buildSetupApproved: Bool = false
    ) async throws -> Bool {
        let path = try Self.safe(rawPath)
        if Self.isBuildSetup(path), !buildSetupApproved { throw ChangeWorkspaceError.buildSetupApprovalRequired(path) }
        switch try await readDecoded(path) {
        case .text(let document, _):
            let existedInBase: Bool
            if case .write(_, _, let prevExisted)? = changes[path] {
                existedInBase = prevExisted
            } else {
                existedInBase = true
            }
            let combined = document.text + text
            let data = TextFileCodec.encode(combined, preserving: document)
            guard TextFileCodec.decode(data) != nil else { throw ChangeWorkspaceError.notText(path) }
            changes[path] = .write(path: path, data: data, existed: existedInBase)
            return false
        case .missing:
            guard createIfMissing else { throw ChangeWorkspaceError.missing(path) }
            try await create(path: path, text: text, buildSetupApproved: buildSetupApproved)
            return true
        case .folder, .binary, .tooLarge, .symlink:
            throw ChangeWorkspaceError.notText(path)
        }
    }

    private static func fuzzyUniqueLineReplacement(source: String, oldText: String, newText: String) -> String? {
        let srcLines = source.components(separatedBy: "\n")
        let oldLines = oldText.components(separatedBy: "\n")
        guard !oldLines.isEmpty, oldLines.count <= srcLines.count else { return nil }
        let trimmedOld = oldLines.map { $0.trimmingCharacters(in: .whitespaces) }
        guard trimmedOld.contains(where: { !$0.isEmpty }) else { return nil }

        var matches: [Int] = []
        let lastStart = srcLines.count - oldLines.count
        if lastStart >= 0 {
            for start in 0...lastStart {
                var ok = true
                for offset in 0..<oldLines.count {
                    if srcLines[start + offset].trimmingCharacters(in: .whitespaces) != trimmedOld[offset] {
                        ok = false
                        break
                    }
                }
                if ok { matches.append(start) }
                if matches.count > 1 { return nil }
            }
        }
        guard matches.count == 1 else { return nil }
        let idx = matches[0]
        var resultLines = Array(srcLines[0..<idx])
        resultLines.append(contentsOf: newText.components(separatedBy: "\n"))
        resultLines.append(contentsOf: srcLines[(idx + oldLines.count)...])
        return resultLines.joined(separator: "\n")
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

/// Builds clean unified diffs (`@@ -oldStart,oldCount +newStart,newCount @@`) with context lines
/// so both human diff viewers and `git apply` work accurately on large files.
enum UnifiedDiffBuilder {
    enum EditOp {
        case equal(String)
        case delete(String)
        case insert(String)
    }

    static func splitLines(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        var lines = normalized.components(separatedBy: "\n")
        if normalized.hasSuffix("\n") {
            lines.removeLast()
        }
        return lines
    }

    static func filePatch(oldPath: String, newPath: String, oldText: String, newText: String, context: Int = 3) -> String? {
        if oldText == newText && oldPath != "/dev/null" && newPath != "/dev/null" {
            return nil
        }
        let oldLines = oldPath == "/dev/null" ? [] : splitLines(oldText)
        let newLines = newPath == "/dev/null" ? [] : splitLines(newText)
        let ops = diffLines(oldLines, newLines)
        guard ops.contains(where: {
            if case .equal = $0 { return false }
            return true
        }) else {
            return nil
        }

        // Group changed regions with `context` surrounding equal lines into unified `@@` hunks.
        let changedIndices = ops.indices.filter {
            if case .equal = ops[$0] { return false }
            return true
        }
        guard let firstChanged = changedIndices.first else { return nil }

        var groups: [ClosedRange<Int>] = []
        var groupStart = max(0, firstChanged - context)
        var groupEnd = min(ops.count - 1, firstChanged + context)
        for idx in changedIndices.dropFirst() {
            let candidateStart = max(0, idx - context)
            let candidateEnd = min(ops.count - 1, idx + context)
            if candidateStart <= groupEnd + 1 {
                groupEnd = max(groupEnd, candidateEnd)
            } else {
                groups.append(groupStart...groupEnd)
                groupStart = candidateStart
                groupEnd = candidateEnd
            }
        }
        groups.append(groupStart...groupEnd)

        // Precompute (oldLineNumberBeforeOp, newLineNumberBeforeOp), 1-indexed.
        var oldBefore = Array(repeating: 1, count: ops.count + 1)
        var newBefore = Array(repeating: 1, count: ops.count + 1)
        var oCursor = 1
        var nCursor = 1
        for (i, op) in ops.enumerated() {
            oldBefore[i] = oCursor
            newBefore[i] = nCursor
            switch op {
            case .equal:
                oCursor += 1
                nCursor += 1
            case .delete:
                oCursor += 1
            case .insert:
                nCursor += 1
            }
        }

        var outputLines: [String] = ["--- \(oldPath)", "+++ \(newPath)"]
        for range in groups {
            var oldCount = 0
            var newCount = 0
            var body: [String] = []
            for i in range {
                switch ops[i] {
                case .equal(let line):
                    oldCount += 1
                    newCount += 1
                    body.append(" " + line)
                case .delete(let line):
                    oldCount += 1
                    body.append("-" + line)
                case .insert(let line):
                    newCount += 1
                    body.append("+" + line)
                }
            }
            let oldStart = oldCount == 0 ? max(0, oldBefore[range.lowerBound] - 1) : oldBefore[range.lowerBound]
            let newStart = newCount == 0 ? max(0, newBefore[range.lowerBound] - 1) : newBefore[range.lowerBound]
            outputLines.append("@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@")
            outputLines.append(contentsOf: body)
        }
        return outputLines.joined(separator: "\n")
    }

    private static func diffLines(_ a: [String], _ b: [String]) -> [EditOp] {
        var prefix = 0
        while prefix < a.count && prefix < b.count && a[prefix] == b[prefix] {
            prefix += 1
        }
        var suffix = 0
        while suffix < (a.count - prefix) && suffix < (b.count - prefix)
            && a[a.count - 1 - suffix] == b[b.count - 1 - suffix] {
            suffix += 1
        }

        var result: [EditOp] = []
        result.reserveCapacity(a.count + b.count)
        for i in 0..<prefix {
            result.append(.equal(a[i]))
        }

        let aMid = Array(a[prefix..<(a.count - suffix)])
        let bMid = Array(b[prefix..<(b.count - suffix)])
        result.append(contentsOf: diffMiddle(aMid, bMid))

        for i in (a.count - suffix)..<a.count {
            result.append(.equal(a[i]))
        }
        return result
    }

    private static func diffMiddle(_ a: [String], _ b: [String]) -> [EditOp] {
        if a.isEmpty { return b.map(EditOp.insert) }
        if b.isEmpty { return a.map(EditOp.delete) }

        // If small/medium, run exact LCS DP; if huge, split on unique Patience anchor lines first!
        if Int64(a.count) * Int64(b.count) <= 1_500_000 {
            return exactLCS(a, b)
        }

        // Patience-style unique anchor decomposition so 10,000-line files diff in milliseconds.
        var countA: [String: (count: Int, index: Int)] = [:]
        for (i, line) in a.enumerated() where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            if let existing = countA[line] { countA[line] = (existing.count + 1, existing.index) }
            else { countA[line] = (1, i) }
        }
        var countB: [String: (count: Int, index: Int)] = [:]
        for (j, line) in b.enumerated() where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            if let existing = countB[line] { countB[line] = (existing.count + 1, existing.index) }
            else { countB[line] = (1, j) }
        }

        // Collect unique matching pairs ordered by `a` index, then take LIS on `b` index.
        var pairs: [(i: Int, j: Int)] = []
        for (i, line) in a.enumerated() {
            if let ca = countA[line], ca.count == 1, let cb = countB[line], cb.count == 1 {
                pairs.append((i, cb.index))
            }
        }
        let anchors = longestIncreasingAnchors(pairs)
        guard !anchors.isEmpty else {
            return a.map(EditOp.delete) + b.map(EditOp.insert)
        }

        var ops: [EditOp] = []
        var prevA = 0
        var prevB = 0
        for anchor in anchors {
            ops.append(contentsOf: diffLines(Array(a[prevA..<anchor.i]), Array(b[prevB..<anchor.j])))
            ops.append(.equal(a[anchor.i]))
            prevA = anchor.i + 1
            prevB = anchor.j + 1
        }
        ops.append(contentsOf: diffLines(Array(a[prevA..<a.count]), Array(b[prevB..<b.count])))
        return ops
    }

    private static func longestIncreasingAnchors(_ pairs: [(i: Int, j: Int)]) -> [(i: Int, j: Int)] {
        guard !pairs.isEmpty else { return [] }
        var tails: [Int] = []
        var prev = Array(repeating: -1, count: pairs.count)
        for idx in pairs.indices {
            let target = pairs[idx].j
            var lo = 0, hi = tails.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if pairs[tails[mid]].j < target { lo = mid + 1 }
                else { hi = mid }
            }
            if lo > 0 { prev[idx] = tails[lo - 1] }
            if lo == tails.count { tails.append(idx) }
            else { tails[lo] = idx }
        }
        var seq: [(i: Int, j: Int)] = []
        var cursor = tails.last ?? -1
        while cursor >= 0 {
            seq.append(pairs[cursor])
            cursor = prev[cursor]
        }
        return seq.reversed()
    }

    private static func exactLCS(_ a: [String], _ b: [String]) -> [EditOp] {
        let n = a.count, m = b.count
        let rowStride = m + 1
        var dp = Array(repeating: Int32(0), count: (n + 1) * rowStride)
        for i in Swift.stride(from: n - 1, through: 0, by: -1) {
            let row = i * rowStride
            let nextRow = (i + 1) * rowStride
            let lineA = a[i]
            for j in Swift.stride(from: m - 1, through: 0, by: -1) {
                if lineA == b[j] {
                    dp[row + j] = dp[nextRow + j + 1] + 1
                } else {
                    let down = dp[nextRow + j]
                    let right = dp[row + j + 1]
                    dp[row + j] = down >= right ? down : right
                }
            }
        }
        var ops: [EditOp] = []
        ops.reserveCapacity(n + m)
        var i = 0, j = 0
        while i < n && j < m {
            if a[i] == b[j] {
                ops.append(.equal(a[i]))
                i += 1
                j += 1
            } else if dp[(i + 1) * rowStride + j] >= dp[i * rowStride + j + 1] {
                ops.append(.delete(a[i]))
                i += 1
            } else {
                ops.append(.insert(b[j]))
                j += 1
            }
        }
        while i < n { ops.append(.delete(a[i])); i += 1 }
        while j < m { ops.append(.insert(b[j])); j += 1 }
        return ops
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
