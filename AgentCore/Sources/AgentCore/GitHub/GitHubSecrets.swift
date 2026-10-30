import Foundation
import Clibsodium

public enum GitHubSecretError: Error, Sendable, Equatable {
    case invalidPublicKey
    case encryptionFailed
    case invalidReviewedRevision
}

/// GitHub repository secrets use libsodium's anonymous sealed-box format.
public enum GitHubSealedBox {
    public static func encrypt(_ value: String, publicKeyBase64: String) throws -> String {
        guard let key = Data(base64Encoded: publicKeyBase64), key.count == 32 else {
            throw GitHubSecretError.invalidPublicKey
        }
        let message = Array(value.utf8)
        guard !message.isEmpty else { throw GitHubSecretError.encryptionFailed }
        var cipher = [UInt8](repeating: 0, count: message.count + Int(crypto_box_sealbytes()))
        guard sodium_init() >= 0 else { throw GitHubSecretError.encryptionFailed }
        let result = key.withUnsafeBytes { keyBytes in
            message.withUnsafeBytes { messageBytes in
                crypto_box_seal(
                    &cipher,
                    messageBytes.bindMemory(to: UInt8.self).baseAddress!,
                    UInt64(message.count),
                    keyBytes.bindMemory(to: UInt8.self).baseAddress!
                )
            }
        }
        guard result == 0 else { throw GitHubSecretError.encryptionFailed }
        return Data(cipher).base64EncodedString()
    }
}

public extension GitHubClient {
    func actionsPublicKey(_ repo: RepoRef) async throws -> GitHubActionsPublicKey {
        try await get(GitHubActionsPublicKey.self, Self.path(repo, "/actions/secrets/public-key"))
    }

    /// Encrypts locally before sending. The clear value is never part of an HTTP body or URL.
    func putActionsSecret(_ repo: RepoRef, name: String, value: String) async throws {
        let key = try await actionsPublicKey(repo)
        let encrypted = try GitHubSealedBox.encrypt(value, publicKeyBase64: key.key)
        _ = try await send(
            "PUT",
            Self.path(repo, "/actions/secrets/\(Self.escape(name))"),
            body: ["encrypted_value": .string(encrypted), "key_id": .string(key.keyID)]
        )
    }
}

/// Installs the small target-repo caller only after the app has shown a confirmation and the
/// person has tapped the setup button.
public actor AutonomousSetup {
    public static let callerPath = ".github/workflows/maipa-g.yml"
    public static func callerWorkflow(reviewedRevision: String) throws -> String {
        let revision = reviewedRevision.lowercased()
        guard revision.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil else {
            throw GitHubSecretError.invalidReviewedRevision
        }
        return """
        name: MAIPA-G Autonomous

        on:
          workflow_dispatch:
            inputs:
              job_id:
                description: Private MAIPA-G job id
                required: true
                type: string
              target_ref:
                description: Target branch
                required: true
                type: string
              data_owner:
                description: Private data owner
                required: true
                type: string
              data_repo:
                description: Private data repository
                required: true
                type: string
              data_branch:
                description: Private data branch
                required: true
                type: string

        permissions:
          actions: write
          contents: write
          pull-requests: write
          checks: read
          statuses: read

        jobs:
          agent:
            uses: 2c2bhdhw9z-cell/MAIPA-G/.github/workflows/agent.yml@\(revision)
            with:
              job_id: ${{ inputs.job_id }}
              target_ref: ${{ inputs.target_ref }}
              data_owner: ${{ inputs.data_owner }}
              data_repo: ${{ inputs.data_repo }}
              data_branch: ${{ inputs.data_branch }}
              maipag_revision: \(revision)
            secrets:
              MAIPAG_APP_ID: ${{ secrets.MAIPAG_APP_ID }}
              MAIPAG_APP_PRIVATE_KEY: ${{ secrets.MAIPAG_APP_PRIVATE_KEY }}
              OPENROUTER_API_KEY: ${{ secrets.OPENROUTER_API_KEY }}
              MAIPAG_MCP_SECRETS: ${{ secrets.MAIPAG_MCP_SECRETS }}
        """
    }

    private let github: GitHubClient
    public init(github: GitHubClient) { self.github = github }

    public func isInstalled(in repo: RepoRef, ref: String) async throws -> Bool {
        do {
            _ = try await github.fileContents(repo, path: Self.callerPath, ref: ref)
            return true
        } catch let error as GitHubAPIError where error.isNotFound {
            return false
        }
    }

    /// The caller must obtain an explicit user confirmation before invoking this method.
    public func install(
        in repo: RepoRef,
        branch: String,
        secrets: [String: String],
        reviewedRevision: String
    ) async throws -> String {
        for (name, value) in secrets.sorted(by: { $0.key < $1.key }) {
            try await github.putActionsSecret(repo, name: name, value: value)
        }
        guard let head = try await github.branchHead(repo, branch: branch) else {
            throw GitHubChangeFailure.noHead
        }
        let workflow = try Self.callerWorkflow(reviewedRevision: reviewedRevision)
        let blob = try await github.createBlob(repo, contents: Data(workflow.utf8))
        let baseTree = try await github.commitTree(repo, commit: head)
        let tree = try await github.createTree(repo, base: baseTree, changes: [.init(path: Self.callerPath, blobSHA: blob)])
        let commit = try await github.createCommit(
            repo,
            message: "Set up MAIPA-G Autonomous [skip ci]",
            tree: tree,
            parents: [head]
        )
        try await github.updateBranch(repo, branch: branch, to: commit)
        return commit
    }
}
