import Foundation

public struct RepoWriteRules: Sendable, Hashable {
    public var directSave: Bool
    public var reason: String?
    public init(directSave: Bool = false, reason: String? = nil) { self.directSave = directSave; self.reason = reason }
}

public enum GitHubChangeFailure: Error, Sendable, CustomStringConvertible {
    case noHead, pullRequestClosed, staleUndo
    public var description: String {
        switch self {
        case .noHead: return "The selected branch has no commit to save on."
        case .pullRequestClosed: return "That pull request is no longer open. Start a new save."
        case .staleUndo: return "Undo stopped because someone changed the branch after MAIPA-G saved."
        }
    }
}

/// Saves one staged overlay through GitHub's Git Data API, following repository rules and Kiro's
/// default side-branch/pull-request behavior.
public actor GitHubChangeService {
    private let github: GitHubClient
    public init(github: GitHubClient) { self.github = github }

    public func resolveRules(in workspace: RepoWorkspace, directSaveSetting: Bool) async -> RepoWriteRules {
        if directSaveSetting { return RepoWriteRules(directSave: true, reason: "Direct save is on for this repo.") }
        guard let tree = try? await workspace.tree() else { return RepoWriteRules() }
        let candidates = tree.entries.filter { entry in
            let lower = entry.path.lowercased()
            return entry.isFile && (lower == "agents.md" || lower.hasSuffix("/agents.md") || lower.contains(".kiro/steering/") || lower.hasSuffix("owner-rules.md"))
        }.prefix(20)
        for entry in candidates {
            guard case .text(let text, _) = try? await workspace.readFile(entry.path) else { continue }
            let lower = text.lowercased()
            let forbidsBranches = lower.contains("no branches") || lower.contains("never create a branch") || lower.contains("do not create branches")
            let forbidsPRs = lower.contains("no pull request") || lower.contains("no prs") || lower.contains("never open") && lower.contains("pull request")
            if forbidsBranches || forbidsPRs {
                return RepoWriteRules(directSave: true, reason: "\(entry.path) requires direct saves.")
            }
        }
        return RepoWriteRules()
    }

    public func save(
        _ workspace: ChangeWorkspace,
        selectedBranch: String,
        defaultBranch: String,
        rules: RepoWriteRules,
        title: String,
        body: String = "Changes made by MAIPA-G."
    ) async throws -> SaveReceipt {
        let staged = await workspace.stagedChanges()
        guard !staged.isEmpty else { throw ChangeWorkspaceError.noChanges }
        let repo = workspace.base.repo
        let selectedHead = try await github.branchHead(repo, branch: selectedBranch)
        guard let selectedHead else { throw GitHubChangeFailure.noHead }
        guard selectedHead == workspace.base.commit else { throw ChangeWorkspaceError.staleHead(expected: workspace.base.commit, actual: selectedHead) }

        let usePR = !rules.directSave
        let targetBranch: String
        if usePR && selectedBranch == defaultBranch {
            targetBranch = Self.branchName(title)
            try await github.createBranch(repo, branch: targetBranch, from: selectedHead)
        } else {
            targetBranch = selectedBranch
        }

        let baseTree = try await github.commitTree(repo, commit: selectedHead)
        var treeChanges: [GitHubClient.TreeChange] = []
        var states: [SaveReceipt.FileState] = []
        for change in staged {
            let before = try await workspace.baseBlob(for: change.path)
            switch change {
            case .write(_, let data, _):
                let after = try await github.createBlob(repo, contents: data)
                treeChanges.append(.init(path: change.path, blobSHA: after))
                states.append(.init(path: change.path, beforeBlob: before, afterBlob: after))
            case .delete:
                treeChanges.append(.init(path: change.path, blobSHA: nil))
                states.append(.init(path: change.path, beforeBlob: before, afterBlob: nil))
            }
        }
        let tree = try await github.createTree(repo, base: baseTree, changes: treeChanges)
        let commit = try await github.createCommit(repo, message: title, tree: tree, parents: [selectedHead])
        try await github.updateBranch(repo, branch: targetBranch, to: commit)

        var pullRequest: GitHubPullRequest?
        if usePR {
            pullRequest = try await github.openPullRequest(repo, title: title, body: body, head: targetBranch, base: defaultBranch)
        }
        await workspace.discardAll()
        return SaveReceipt(repo: repo, branch: targetBranch, baseCommit: selectedHead, savedCommit: commit, files: states, pullRequest: pullRequest)
    }

    public func addIt(_ receipt: SaveReceipt) async throws {
        guard let pull = receipt.pullRequest else { return }
        let current = try await github.pullRequest(receipt.repo, number: pull.number)
        guard current.state == "open" else { throw GitHubChangeFailure.pullRequestClosed }
        try await github.mergePullRequest(receipt.repo, number: pull.number, title: pull.title)
        try await github.deleteBranch(receipt.repo, branch: receipt.branch)
    }

    public func throwAway(_ receipt: SaveReceipt) async throws {
        guard let pull = receipt.pullRequest else { return }
        let current = try await github.pullRequest(receipt.repo, number: pull.number)
        if current.state == "open" { _ = try await github.closePullRequest(receipt.repo, number: pull.number) }
        try await github.deleteBranch(receipt.repo, branch: receipt.branch)
    }

    /// Reverses the receipt only while its save is still the branch head.
    public func undo(_ receipt: SaveReceipt) async throws -> SaveReceipt {
        let head = try await github.branchHead(receipt.repo, branch: receipt.branch)
        guard head == receipt.savedCommit else { throw ChangeWorkspaceError.staleHead(expected: receipt.savedCommit, actual: head) }
        let baseTree = try await github.commitTree(receipt.repo, commit: receipt.savedCommit)
        let inverse = receipt.files.map { GitHubClient.TreeChange(path: $0.path, blobSHA: $0.beforeBlob) }
        let tree = try await github.createTree(receipt.repo, base: baseTree, changes: inverse)
        let commit = try await github.createCommit(receipt.repo, message: "Undo MAIPA-G save", tree: tree, parents: [receipt.savedCommit])
        try await github.updateBranch(receipt.repo, branch: receipt.branch, to: commit)
        return SaveReceipt(repo: receipt.repo, branch: receipt.branch, baseCommit: receipt.savedCommit, savedCommit: commit, files: receipt.files.map { .init(path: $0.path, beforeBlob: $0.afterBlob, afterBlob: $0.beforeBlob) }, pullRequest: receipt.pullRequest)
    }

    static func branchName(_ title: String) -> String {
        let slug = String(title.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }.split(separator: "-").prefix(6).joined(separator: "-"))
        return "maipa-g/\(slug.isEmpty ? "changes" : slug)-\(UUID().uuidString.lowercased().prefix(8))"
    }
}
