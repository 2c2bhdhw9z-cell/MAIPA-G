import Foundation

/// Publishes a checked local workspace through GitHub's Git Data API. Untrusted shell and MCP
/// children never receive a credential and cannot perform network Git operations themselves.
public struct GitHubWorkspacePublisher: Sendable {
    public let github: GitHubClient
    public let repo: RepoRef
    public let workspace: URL

    public init(github: GitHubClient, repo: RepoRef, workspace: URL) {
        self.github = github; self.repo = repo; self.workspace = workspace
    }

    public func publish(branch: String, baseRef: String, expectedRemoteHead: String? = nil, message: String) async throws -> String {
        let localHead = try await git(["rev-parse", "HEAD"]).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseHead = try await github.branchHead(repo, branch: baseRef)
        guard let baseHead else { throw GitHubChangeFailure.noHead }
        let currentHead = try await github.branchHead(repo, branch: branch)
        if let expectedRemoteHead {
            guard currentHead == expectedRemoteHead else { throw ChangeWorkspaceError.staleHead(expected: expectedRemoteHead, actual: currentHead) }
        } else if branch == baseRef {
            guard currentHead == localHead else { throw ChangeWorkspaceError.staleHead(expected: localHead, actual: currentHead) }
        } else if let currentHead, currentHead != localHead {
            throw ChangeWorkspaceError.staleHead(expected: localHead, actual: currentHead)
        }
        if currentHead == nil, baseHead != localHead {
            throw ChangeWorkspaceError.staleHead(expected: localHead, actual: baseHead)
        }
        let parent = currentHead ?? baseHead
        _ = try await git(["add", "-A"])
        defer { Task { _ = try? await git(["reset"]) } }
        let names = try await git(["diff", "--cached", "--name-only", "-z", localHead, "--", "."], outputLimit: 20_000_000)
            .stdout.split(separator: "\0").map(String.init)
        guard !names.isEmpty else { return currentHead ?? baseHead }
        var changes: [GitHubClient.TreeChange] = []
        for path in names {
            guard SnapshotStore.isSafeRelativePath(path) else { throw ToolInputError("A changed path is outside the repository.") }
            let url = workspace.appendingPathComponent(path)
            if FileManager.default.fileExists(atPath: url.path) {
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                let isSymlink = attributes[.type] as? FileAttributeType == .typeSymbolicLink
                let data = isSymlink
                    ? Data(try FileManager.default.destinationOfSymbolicLink(atPath: url.path).utf8)
                    : try Data(contentsOf: url, options: .mappedIfSafe)
                let blob = try await github.createBlob(repo, contents: data)
                let modeLine = try await git(["ls-files", "-s", "--", path], allowFailure: true).stdout
                let indexedMode = modeLine.split(separator: " ").first.map(String.init) ?? "100644"
                let mode = isSymlink ? "120000" : indexedMode
                changes.append(.init(path: path, blobSHA: blob, mode: ["100644", "100755", "120000"].contains(mode) ? mode : "100644"))
            } else {
                changes.append(.init(path: path, blobSHA: nil))
            }
        }
        if currentHead == nil { try await github.createBranch(repo, branch: branch, from: baseHead) }
        let tree = try await github.createTree(repo, base: try await github.commitTree(repo, commit: parent), changes: changes)
        let commit = try await github.createCommit(repo, message: message, tree: tree, parents: [parent])
        try await github.updateBranch(repo, branch: branch, to: commit)
        return commit
    }

    private func git(_ arguments: [String], allowFailure: Bool = false, outputLimit: Int = 80_000) async throws -> ProcessResult {
        let result = try await BoundedProcess.run(executable: "/usr/bin/git", arguments: arguments, directory: workspace, timeout: 600, outputLimit: outputLimit)
        if result.exitCode != 0 && !allowFailure { throw CloudRunnerError.commandFailed }
        return result
    }
}

public enum UserRequestPolicy {
    public static func explicitlyRequestsBuild(_ request: String) -> Bool {
        let text = request.lowercased()
        if ["do not build", "don't build", "without building", "no build"].contains(where: text.contains) { return false }
        return ["build the", "run the build", "start the build", "build an ipa", "build ipa", "run ci", "run the workflow", "start the workflow"].contains(where: text.contains)
    }
}

public actor CloudToolResults {
    public private(set) var pullRequest: GitHubPullRequest?
    public private(set) var buildURL: String?
    public private(set) var artifactURL: String?
    public private(set) var additionalCost: Double = 0

    public init() {}
    public func record(pullRequest: GitHubPullRequest) { self.pullRequest = pullRequest }
    public func record(buildURL: String?) { self.buildURL = buildURL }
    public func record(artifactURL: String?) { self.artifactURL = artifactURL }
    public func add(cost: Double) { additionalCost += cost }
}

/// The GitHub capabilities supplied to built-in cloud agents. Keeping the names in one factory
/// makes role-policy filtering testable through the same assembly used by CloudRunner.
public enum CloudToolAssembly {
    public static let names: Set<String> = [
        "read_pull_request", "read_pull_request_comments", "read_checks", "read_workflow_logs",
        "list_workflows", "dispatch_workflow", "list_artifacts", "inspect_ipa", "read_releases",
        "create_pull_request", "reply_to_review_comment",
    ]

    public static func availableToolNames(for agent: AgentDefinition) -> Set<String> {
        Set(names.union(["inspect_workspace", "run_shell"]).filter { agent.permits(tool: $0) })
    }

    public static func make(
        github: GitHubClient,
        repo: RepoRef,
        ref: String,
        workspace: URL,
        defaultBranch: String,
        directSave: Bool,
        buildExplicitlyRequested: Bool,
        results: CloudToolResults,
        logger: RedactingLogger = RedactingLogger()
    ) -> [any AgentTool] {
        names.sorted().map {
            CloudGitHubTool(name: $0, github: github, repo: repo, ref: ref, workspace: workspace,
                            defaultBranch: defaultBranch, directSave: directSave,
                            buildExplicitlyRequested: buildExplicitlyRequested, results: results, logger: logger)
        }
    }
}

private struct CloudGitHubTool: AgentTool {
    let name: String
    let github: GitHubClient
    let repo: RepoRef
    let ref: String
    let workspace: URL
    let defaultBranch: String
    let directSave: Bool
    let buildExplicitlyRequested: Bool
    let results: CloudToolResults
    let logger: RedactingLogger

    var spec: ToolSpec {
        let properties: JSONValue
        let required: [JSONValue]
        switch name {
        case "read_pull_request", "read_pull_request_comments", "reply_to_review_comment":
            properties = ["number": ["type": "integer"], "body": ["type": "string"]]
            required = name == "reply_to_review_comment" ? ["number", "body"] : ["number"]
        case "read_workflow_logs":
            properties = ["run_id": ["type": "integer"]]; required = ["run_id"]
        case "dispatch_workflow":
            properties = ["workflow": ["type": "string"], "ref": ["type": "string"]]; required = ["workflow"]
        case "list_artifacts":
            properties = ["run_id": ["type": "integer"]]; required = []
        case "inspect_ipa":
            properties = ["artifact_id": ["type": "integer"]]; required = ["artifact_id"]
        case "create_pull_request":
            properties = ["title": ["type": "string"], "body": ["type": "string"], "base": ["type": "string"]]; required = ["title"]
        default:
            properties = ["ref": ["type": "string"]]; required = []
        }
        return ToolSpec(name: name, description: description, parameters: [
            "type": "object", "properties": properties, "required": .array(required), "additionalProperties": false,
        ])
    }

    func runningSummary(for arguments: JSONValue) -> String { "Using GitHub · \(name.replacingOccurrences(of: "_", with: " "))…" }

    func approvalRequest(for arguments: JSONValue) async -> ToolApprovalRequest? {
        if name == "dispatch_workflow", !buildExplicitlyRequested {
            return ToolApprovalRequest(question: "Start this GitHub Actions workflow?", allowLabel: "Start build")
        }
        return nil
    }

    func run(arguments: JSONValue, progress: @escaping @Sendable (String) -> Void) async throws -> ToolOutput {
        if name == "dispatch_workflow", !buildExplicitlyRequested {
            throw ToolInputError("The original request did not ask to start a build.")
        }
        return try await perform(arguments: arguments, progress: progress)
    }

    func runApproved(arguments: JSONValue, progress: @escaping @Sendable (String) -> Void) async throws -> ToolOutput {
        try await perform(arguments: arguments, progress: progress)
    }

    private func perform(arguments: JSONValue, progress: @escaping @Sendable (String) -> Void) async throws -> ToolOutput {
        progress(runningSummary(for: arguments))
        switch name {
        case "list_workflows":
            let response = try await github.send("GET", GitHubClient.path(repo, "/actions/workflows"), query: ["per_page": "100"])
            return output("Listed workflows", response.text)
        case "dispatch_workflow":
            let workflow = try arguments.requiredString("workflow")
            let target = arguments.optionalString("ref") ?? ref
            try await github.dispatchWorkflow(repo, workflow: workflow, ref: target)
            return output("Started \(workflow)", "Dispatched \(workflow) on \(target).")
        case "read_checks":
            let target = arguments.optionalString("ref") ?? ref
            let checks = try await github.checkRuns(repo, ref: target)
            let statuses = try await github.commitStatuses(repo, ref: target)
            let text = checks.map { "\($0.name): \($0.conclusion ?? $0.status) \($0.htmlURL ?? "")" } + statuses.map { "\($0.context): \($0.state) \($0.targetURL ?? "")" }
            return output("Read checks", text.isEmpty ? "No checks were reported." : text.joined(separator: "\n"))
        case "read_workflow_logs":
            let id = try requiredInt("run_id", in: arguments)
            async let run = github.workflowRun(repo, runID: id)
            async let jobs = github.workflowJobs(repo, runID: id)
            let (runValue, jobValues) = try await (run, jobs)
            let archive = (try? await github.workflowLogArchive(repo, runID: id)).map(GitHubRunWatcher.readLogs) ?? ""
            await results.record(buildURL: runValue.htmlURL)
            let summary = jobValues.map { job in
                let steps = job.steps.map { "  \($0.name): \($0.conclusion ?? $0.status)" }.joined(separator: "\n")
                return "\(job.name): \(job.conclusion ?? job.status)\n\(steps)\n\(job.htmlURL)"
            }.joined(separator: "\n\n")
            let text = logger.redact([summary, archive].filter { !$0.isEmpty }.joined(separator: "\n\nActual redacted logs:\n"))
            return output("Read workflow run \(id)", text)
        case "list_artifacts":
            let artifacts = try await github.artifacts(repo, runID: arguments.optionalInt("run_id"))
            let text = artifacts.map { "\($0.id) \($0.name) \($0.sizeInBytes) bytes\($0.expired ? " (expired)" : "")" }.joined(separator: "\n")
            if let first = artifacts.first(where: { !$0.expired }) {
                await results.record(artifactURL: first.archiveDownloadURL)
            }
            return output("Listed artifacts", text.isEmpty ? "No artifacts were found." : text)
        case "inspect_ipa":
            let artifactID = try requiredInt("artifact_id", in: arguments)
            let archive = try await github.artifactArchive(repo, artifactID: artifactID)
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("maipag-ipa-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }
            try PreviewArtifactExtractor.extract(archive, to: root)
            guard let ipa = Self.firstFile(withExtension: "ipa", under: root) else { throw ToolInputError("That artifact does not contain an IPA.") }
            let checker = workspace.appendingPathComponent(".maipag-runner/scripts/check-ipa.py")
            guard FileManager.default.fileExists(atPath: checker.path) else { throw ToolInputError("The independent IPA checker is unavailable.") }
            let checked = try await BoundedProcess.run(executable: "/usr/bin/python3", arguments: [checker.path, ipa.path], directory: workspace, timeout: 180)
            let detail = [checked.stdout, checked.stderr].filter { !$0.isEmpty }.joined(separator: "\n")
            guard checked.exitCode == 0 else { throw ToolInputError(detail.isEmpty ? "The IPA check failed." : detail) }
            return output("Checked the IPA", detail)
        case "read_releases":
            let release = try await github.latestRelease(repo)
            let text = release.map { "\($0.tagName) \($0.htmlURL)\n" + $0.assets.map { "\($0.name): \($0.downloadURL)" }.joined(separator: "\n") } ?? "No release was found."
            return output("Read latest release", text)
        case "read_pull_request":
            let pull = try await github.pullRequest(repo, number: requiredInt("number", in: arguments))
            return output("Read pull request #\(pull.number)", "#\(pull.number) \(pull.title)\nState: \(pull.state)\nHead: \(pull.headBranch)\nBase: \(pull.baseBranch)\n\(pull.htmlURL)")
        case "read_pull_request_comments":
            let number = try requiredInt("number", in: arguments)
            async let commentsTask = github.issueComments(repo, number: number)
            async let reviewsTask = github.pullRequestReviews(repo, number: number)
            let (comments, reviews) = try await (commentsTask, reviewsTask)
            let values = comments + reviews
            return output("Read pull request comments", values.map { $0.jsonString() }.joined(separator: "\n"))
        case "create_pull_request":
            guard !directSave else { throw ToolInputError("Repository rules require a direct save, so no pull request may be opened.") }
            let title = try arguments.requiredString("title")
            _ = try await GitHubWorkspacePublisher(github: github, repo: repo, workspace: workspace)
                .publish(branch: ref, baseRef: defaultBranch, message: title)
            let pull = try await github.openPullRequest(repo, title: title, body: arguments.optionalString("body") ?? "Changes made and checked by MAIPA-G Autonomous.", head: ref, base: arguments.optionalString("base") ?? defaultBranch)
            await results.record(pullRequest: pull)
            return output("Opened pull request #\(pull.number)", pull.htmlURL)
        case "reply_to_review_comment":
            let number = try requiredInt("number", in: arguments)
            let body = try arguments.requiredString("body")
            _ = try await github.addPullRequestComment(repo, number: number, body: body)
            return output("Replied on pull request #\(number)", "Posted the verified response.")
        default:
            throw ToolInputError("Unsupported GitHub tool \(name).")
        }
    }

    private var description: String {
        switch name {
        case "list_workflows": return "List the repository's GitHub Actions workflows without starting one."
        case "dispatch_workflow": return "Start a named GitHub Actions workflow only when the original request asks for a build."
        case "read_checks": return "Read check runs and commit statuses for a ref."
        case "read_workflow_logs": return "Read a workflow run's jobs and step conclusions."
        case "list_artifacts": return "List artifacts, optionally for one workflow run."
        case "inspect_ipa": return "Download an IPA artifact and run MAIPA-G's independent IPA checker."
        case "read_releases": return "Read the latest GitHub release and its assets."
        case "read_pull_request": return "Read one pull request."
        case "read_pull_request_comments": return "Read issue comments and reviews on one pull request."
        case "create_pull_request": return "Commit and push checked workspace changes, then open a pull request."
        case "reply_to_review_comment": return "Post a verified response to pull request feedback."
        default: return name
        }
    }

    private func output(_ summary: String, _ detail: String) -> ToolOutput {
        ToolOutput(forModel: detail.isEmpty ? summary : detail, summary: summary, detail: String(detail.prefix(80_000)))
    }

    private func requiredInt(_ key: String, in arguments: JSONValue) throws -> Int {
        guard let value = arguments.optionalInt(key) else { throw ToolInputError("Missing \"\(key)\".") }
        return value
    }

    @discardableResult
    private func requireGit(_ arguments: [String]) async throws -> ProcessResult {
        let result = try await BoundedProcess.run(executable: "/usr/bin/git", arguments: arguments, directory: workspace, timeout: 600)
        guard result.exitCode == 0 else { throw ToolInputError(result.stderr.isEmpty ? "Git command failed." : result.stderr) }
        return result
    }

    private static func firstFile(withExtension suffix: String, under root: URL) -> URL? {
        guard let values = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return nil }
        return values.compactMap { $0 as? URL }.first { $0.pathExtension.lowercased() == suffix }
    }
}
