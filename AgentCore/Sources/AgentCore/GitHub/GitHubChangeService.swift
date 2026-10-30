import Foundation

public struct RepoRuleDocument: Sendable, Hashable {
    public var path: String
    public var scope: String
    public var text: String

    public init(path: String, text: String) {
        self.path = path; self.text = text
        let lower = path.lowercased()
        if lower.hasSuffix("/agents.md") { scope = String(path.dropLast("AGENTS.md".count)).trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
        else { scope = "" }
    }

    public func applies(to path: String) -> Bool { scope.isEmpty || path == scope || path.hasPrefix(scope + "/") }
}

public struct RepoWriteRules: Sendable, Hashable {
    public var directSave: Bool
    public var reason: String?
    public var documents: [RepoRuleDocument]
    public var deletionDeniedScopes: Set<String>
    public var buildSetupDeniedScopes: Set<String>

    public init(directSave: Bool = false, reason: String? = nil, documents: [RepoRuleDocument] = [], deletionDeniedScopes: Set<String> = [], buildSetupDeniedScopes: Set<String> = []) {
        self.directSave = directSave; self.reason = reason; self.documents = documents
        self.deletionDeniedScopes = deletionDeniedScopes; self.buildSetupDeniedScopes = buildSetupDeniedScopes
    }

    public func permitsDeletion(at path: String) -> Bool { !denied(path, scopes: deletionDeniedScopes) }
    public func permitsBuildSetup(at path: String) -> Bool { !denied(path, scopes: buildSetupDeniedScopes) }
    public var promptText: String {
        documents.prefix(20).map { "Repository rule \($0.path) (scope: \($0.scope.isEmpty ? "whole repository" : $0.scope)):\n\(String($0.text.prefix(20_000)))" }.joined(separator: "\n\n")
    }

    private func denied(_ path: String, scopes: Set<String>) -> Bool {
        scopes.contains("") || scopes.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    public static func resolve(documents values: [(path: String, text: String)], directSaveSetting: Bool) -> RepoWriteRules {
        let documents = values.map(RepoRuleDocument.init)
        var result = RepoWriteRules(directSave: directSaveSetting, reason: directSaveSetting ? "Direct save is on for this repo." : nil, documents: documents)
        for document in documents {
            let lines = document.text.lowercased().components(separatedBy: .newlines)
            let statements = lines.flatMap { line in
                line.components(separatedBy: CharacterSet(charactersIn: ".;"))
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "-*`"))) }
            }
            // Only an unconditional, repository-wide statement selects direct mode. A sentence
            // such as "notes files can go straight to main" is scoped to those files and must not
            // silently send an unrelated README change to the default branch.
            let directStatements: Set<String> = [
                "no branches", "do not create branches", "never create branches", "never create a branch",
                "commit directly to main", "commit directly to master", "push directly to main", "push directly to master",
                "save directly to main", "save directly to master", "do not open pull requests", "never open pull requests",
                "no pull requests", "no pull request",
            ]
            if document.scope.isEmpty, statements.contains(where: directStatements.contains) {
                result.directSave = true
                result.reason = "\(document.path) requires direct saves."
            }
            if lines.contains(where: { line in ["do not delete", "never delete", "must not delete", "deletions are forbidden"].contains(where: line.contains) }) {
                result.deletionDeniedScopes.insert(document.scope)
            }
            if lines.contains(where: { line in ["do not change build setup", "never change build setup", "must not change build setup", "build setup is read-only"].contains(where: line.contains) }) {
                result.buildSetupDeniedScopes.insert(document.scope)
            }
        }
        return result
    }
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
        guard let tree = try? await workspace.tree() else { return RepoWriteRules(directSave: directSaveSetting, reason: directSaveSetting ? "Direct save is on for this repo." : nil) }
        let candidates = tree.entries.filter { entry in
            let lower = entry.path.lowercased()
            return entry.isFile && (lower == "agents.md" || lower.hasSuffix("/agents.md") || lower.contains(".kiro/steering/") || lower.hasSuffix("owner-rules.md"))
        }.sorted {
            let leftDepth = $0.path.split(separator: "/").count, rightDepth = $1.path.split(separator: "/").count
            return leftDepth == rightDepth ? $0.path < $1.path : leftDepth < rightDepth
        }.prefix(100)
        var documents: [(path: String, text: String)] = []
        for entry in candidates {
            guard case .text(let text, _) = try? await workspace.readFile(entry.path) else { continue }
            documents.append((entry.path, text))
        }
        return RepoWriteRules.resolve(documents: documents, directSaveSetting: directSaveSetting)
    }

    public func save(
        _ workspace: ChangeWorkspace,
        selectedBranch: String,
        defaultBranch: String,
        rules: RepoWriteRules,
        title: String,
        body: String = "Changes made by MAIPA-G.",
        activeReceipt: SaveReceipt? = nil
    ) async throws -> SaveReceipt {
        let staged = await workspace.stagedChanges()
        guard !staged.isEmpty else { throw ChangeWorkspaceError.noChanges }
        let repo = workspace.base.repo
        let continuing: SaveReceipt?
        if let activeReceipt, activeReceipt.repo == repo, let pull = activeReceipt.pullRequest {
            let current = try await github.pullRequest(repo, number: pull.number)
            guard current.state == "open" else { throw GitHubChangeFailure.pullRequestClosed }
            continuing = activeReceipt
        } else {
            continuing = nil
        }
        let sourceBranch = continuing?.branch ?? selectedBranch
        let selectedHead = try await github.branchHead(repo, branch: sourceBranch)
        guard let selectedHead else { throw GitHubChangeFailure.noHead }
        guard selectedHead == workspace.base.commit else { throw ChangeWorkspaceError.staleHead(expected: workspace.base.commit, actual: selectedHead) }

        let usePR = continuing != nil || !rules.directSave
        let targetBranch: String
        if let continuing {
            targetBranch = continuing.branch
        } else if usePR && selectedBranch == defaultBranch {
            targetBranch = Self.branchName(title)
            try await github.createBranch(repo, branch: targetBranch, from: selectedHead)
        } else {
            // A selected non-default branch is the working branch, not permission to bypass review.
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
        if let continuing {
            pullRequest = continuing.pullRequest
        } else if usePR {
            pullRequest = try await github.openOrReusePullRequest(repo, title: title, body: body, head: targetBranch, base: defaultBranch)
        }
        await workspace.discardAll()
        return SaveReceipt(repo: repo, branch: targetBranch, baseCommit: selectedHead, savedCommit: commit, files: states, pullRequest: pullRequest)
    }

    public func addIt(_ receipt: SaveReceipt) async throws {
        guard let pull = receipt.pullRequest else { return }
        let current = try await github.pullRequest(receipt.repo, number: pull.number)
        guard current.state == "open" else { throw GitHubChangeFailure.pullRequestClosed }
        try await github.mergePullRequest(receipt.repo, number: pull.number, title: pull.title)
        try await github.deleteBranchIfMAIPAG(receipt.repo, branch: receipt.branch)
    }

    public func throwAway(_ receipt: SaveReceipt) async throws {
        guard let pull = receipt.pullRequest else { return }
        let current = try await github.pullRequest(receipt.repo, number: pull.number)
        if current.state == "open" { _ = try await github.closePullRequest(receipt.repo, number: pull.number) }
        try await github.deleteBranchIfMAIPAG(receipt.repo, branch: receipt.branch)
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
