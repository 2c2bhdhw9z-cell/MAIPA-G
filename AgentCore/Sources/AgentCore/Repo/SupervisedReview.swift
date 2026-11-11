import Foundation

// Kiro's two permission modes (https://kiro.dev/docs/ide/chat/autopilot/,
// https://kiro.dev/docs/privacy-and-security/): Autopilot makes changes on its own; Supervised
// pauses after a turn with file edits so each change can be reviewed and accepted or rejected,
// hunk by hunk. In MAIPA-G the AI stages edits and `save_changes` puts them in the repo, so
// Supervised means: nothing is saved until the person has reviewed every staged change; a rejected
// hunk is put back the way it was in the staged file.

/// Whether the AI works on its own or waits for the person to review each change.
public enum PermissionMode: String, Codable, Sendable, CaseIterable, Identifiable {
    case autopilot, supervised

    public var id: String { rawValue }
    public var title: String { self == .autopilot ? "Autopilot" : "Supervised" }
    public var explanation: String {
        self == .autopilot ? "makes and saves changes on its own" : "you review each change before it's saved"
    }
}

/// One changed region of a file: lines removed from the original and lines put in their place.
public struct ReviewHunk: Sendable, Hashable, Identifiable {
    public var id: Int
    /// Index of the first changed line in the original (0-based).
    public var oldStart: Int
    public var oldLines: [String]
    /// Index of the first changed line in the new text (0-based).
    public var newStart: Int
    public var newLines: [String]

    /// A short unified-diff rendering for the review screen.
    public var patch: String {
        var lines = ["@@ -\(oldStart + 1),\(oldLines.count) +\(newStart + 1),\(newLines.count) @@"]
        lines += oldLines.map { "-" + $0 }
        lines += newLines.map { "+" + $0 }
        return lines.joined(separator: "\n")
    }
}

public enum SupervisedReview {
    /// Above this many line pairs the middle of a file is shown as one hunk, so a huge file can't stall the phone.
    static let maxDiffCells = 4_000_000

    /// The hunks between two versions of a file.
    public static func hunks(old: String, new: String) -> [ReviewHunk] {
        let a = lines(old), b = lines(new)
        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        let midA = Array(a[prefix..<(a.count - suffix)]), midB = Array(b[prefix..<(b.count - suffix)])
        if midA.isEmpty && midB.isEmpty { return [] }
        if midA.count * midB.count > maxDiffCells || midA.isEmpty || midB.isEmpty {
            return [ReviewHunk(id: 0, oldStart: prefix, oldLines: midA, newStart: prefix, newLines: midB)]
        }
        // Longest common subsequence over the middle, then group the differences into hunks.
        let n = midA.count, m = midB.count
        var table = [[Int32]](repeating: [Int32](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                table[i][j] = midA[i] == midB[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var result: [ReviewHunk] = []
        var i = 0, j = 0
        var current: ReviewHunk?
        func flush() {
            if let hunk = current { result.append(ReviewHunk(id: result.count, oldStart: hunk.oldStart, oldLines: hunk.oldLines, newStart: hunk.newStart, newLines: hunk.newLines)) }
            current = nil
        }
        while i < n || j < m {
            if i < n, j < m, midA[i] == midB[j] {
                flush(); i += 1; j += 1
            } else if j < m, i == n || table[i][j + 1] >= table[i + 1][j] {
                if current == nil { current = ReviewHunk(id: 0, oldStart: prefix + i, oldLines: [], newStart: prefix + j, newLines: []) }
                current?.newLines.append(midB[j]); j += 1
            } else {
                if current == nil { current = ReviewHunk(id: 0, oldStart: prefix + i, oldLines: [], newStart: prefix + j, newLines: []) }
                current?.oldLines.append(midA[i]); i += 1
            }
        }
        flush()
        return result
    }

    /// The new text with one hunk put back the way it was (Kiro's per-hunk "reject").
    public static func rejecting(_ hunk: ReviewHunk, new: String) -> String {
        var b = lines(new)
        let end = min(b.count, hunk.newStart + hunk.newLines.count)
        guard hunk.newStart <= b.count, end >= hunk.newStart else { return new }
        b.replaceSubrange(hunk.newStart..<end, with: hunk.oldLines)
        return join(b, trailingNewline: new.hasSuffix("\n") || (new.isEmpty && hunk.oldLines.count > 0))
    }

    /// A staged change's identity for review: same path and same contents. Editing the file again
    /// after it was accepted makes it unreviewed again.
    public static func fingerprint(_ change: StagedChange) -> String {
        switch change {
        case .write(let path, let data, _): return "w:" + path + ":" + Hashing.sha256Hex(data)
        case .delete(let path, _): return "d:" + path
        }
    }

    /// Staged changes the person hasn't accepted yet.
    public static func unreviewed(_ staged: [StagedChange], accepted: Set<String>) -> [StagedChange] {
        staged.filter { !accepted.contains(fingerprint($0)) }
    }

    /// Accepted fingerprints still matching a staged change; stale ones are dropped.
    public static func pruned(_ accepted: Set<String>, staged: [StagedChange]) -> Set<String> {
        accepted.intersection(staged.map(fingerprint))
    }

    static func lines(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var parts = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        if text.hasSuffix("\n") { parts.removeLast() }
        return parts
    }

    static func join(_ lines: [String], trailingNewline: Bool) -> String {
        guard !lines.isEmpty else { return "" }
        return lines.joined(separator: "\n") + (trailingNewline ? "\n" : "")
    }
}

/// In Supervised mode `save_changes` waits until every staged change has been reviewed.
public struct SupervisedSaveGate: AgentTool {
    let inner: any AgentTool
    let unreviewed: @Sendable () async -> [String]

    public init(_ inner: any AgentTool, unreviewed: @escaping @Sendable () async -> [String]) {
        self.inner = inner
        self.unreviewed = unreviewed
    }

    public static func wrap(_ tools: [any AgentTool], unreviewed: @escaping @Sendable () async -> [String]) -> [any AgentTool] {
        tools.map { $0.name == "save_changes" ? SupervisedSaveGate($0, unreviewed: unreviewed) : $0 }
    }

    public var name: String { inner.name }
    public var spec: ToolSpec { inner.spec }
    public var bringsOutsideContent: Bool { inner.bringsOutsideContent }
    public func runningSummary(for arguments: JSONValue) -> String { inner.runningSummary(for: arguments) }
    public func approvalRequest(for arguments: JSONValue) async -> ToolApprovalRequest? {
        await refusal() == nil ? await inner.approvalRequest(for: arguments) : nil
    }
    public func approvalAfterOutsideContent(for arguments: JSONValue) async -> ToolApprovalRequest? {
        await refusal() == nil ? await inner.approvalAfterOutsideContent(for: arguments) : nil
    }

    func refusal() async -> ToolOutput? {
        let waiting = await unreviewed()
        guard !waiting.isEmpty else { return nil }
        let list = waiting.prefix(20).map { "`\($0)`" }.joined(separator: ", ")
        let reason = "Supervised mode: the person reviews each change before it is saved, and \(waiting.count) staged file\(waiting.count == 1 ? " is" : "s are") still waiting for review (\(list)). Don't save. Finish your reply and tell them the changes are ready to review; they accept or reject each change, then ask you to save."
        return ToolOutput(forModel: reason, summary: "Waiting for your review", detail: reason, isError: true)
    }

    public func run(arguments: JSONValue, progress: @escaping @Sendable (String) -> Void) async throws -> ToolOutput {
        if let refused = await refusal() { return refused }
        return try await inner.run(arguments: arguments, progress: progress)
    }
    public func runApproved(arguments: JSONValue, progress: @escaping @Sendable (String) -> Void) async throws -> ToolOutput {
        if let refused = await refusal() { return refused }
        return try await inner.runApproved(arguments: arguments, progress: progress)
    }
}

/// One staged file on the Supervised review screen.
public struct ReviewFile: Sendable, Hashable, Identifiable {
    public enum Status: String, Sendable, Hashable { case created = "Created", edited = "Edited", deleted = "Deleted" }
    public var path: String
    public var status: Status
    /// Hunks to accept or reject one by one; empty for a binary file, which is reviewed whole.
    public var hunks: [ReviewHunk]
    public var isAccepted: Bool
    public var isText: Bool
    public var id: String { path }

    public init(path: String, status: Status, hunks: [ReviewHunk], isAccepted: Bool, isText: Bool) {
        self.path = path; self.status = status; self.hunks = hunks; self.isAccepted = isAccepted; self.isText = isText
    }
}

extension SupervisedReview {
    /// The review screen's entry for one staged change. `texts` is nil for a binary file.
    public static func file(for change: StagedChange, texts: (old: String, new: String)?, accepted: Set<String>) -> ReviewFile {
        let status: ReviewFile.Status
        switch change {
        case .write(_, _, let existed): status = existed ? .edited : .created
        case .delete: status = .deleted
        }
        let hunks = texts.map { hunks(old: $0.old, new: $0.new) } ?? []
        return ReviewFile(path: change.path, status: status, hunks: hunks, isAccepted: accepted.contains(fingerprint(change)), isText: texts != nil)
    }
}
