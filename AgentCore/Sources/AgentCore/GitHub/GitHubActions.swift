import Foundation
import ZIPFoundation

public struct GitHubRunWatchResult: Sendable, Hashable {
    public var runs: [GitHubWorkflowRun]
    public var checks: [GitHubCheckRun]
    public var statuses: [GitHubCommitStatus]
    public var failedLogs: String

    public var succeeded: Bool {
        runs.allSatisfy { ["success", "neutral", "skipped"].contains($0.conclusion ?? "") }
            && checks.allSatisfy { ["success", "neutral", "skipped"].contains($0.conclusion ?? "") }
            && statuses.allSatisfy { $0.state == "success" }
    }
}

/// Finds only checks for the commit MAIPA-G published, waits for terminal results, and returns
/// redacted failed logs. It never selects a run or artifact from another commit.
public struct GitHubRunWatcher: Sendable {
    public typealias Sleeper = @Sendable () async throws -> Void
    private let github: GitHubClient
    private let sleeper: Sleeper
    private let maximumPolls: Int

    public init(github: GitHubClient, maximumPolls: Int = 90, sleeper: @escaping Sleeper = {
        try await Task.sleep(nanoseconds: 20_000_000_000)
    }) {
        self.github = github; self.maximumPolls = max(1, maximumPolls); self.sleeper = sleeper
    }

    public func wait(repo: RepoRef, commit: String, excludingRunID: Int? = nil, redacting logger: RedactingLogger) async throws -> GitHubRunWatchResult {
        var matched: [GitHubWorkflowRun] = []
        var checks: [GitHubCheckRun] = []
        var statuses: [GitHubCommitStatus] = []
        for poll in 0..<maximumPolls {
            matched = try await github.workflowRuns(repo, limit: 100).filter { $0.headSHA == commit && $0.id != excludingRunID }
            checks = (try? await github.checkRuns(repo, ref: commit)) ?? []
            statuses = (try? await github.commitStatuses(repo, ref: commit)) ?? []
            let discovered = !matched.isEmpty || !checks.isEmpty || !statuses.isEmpty
            let runsDone = matched.allSatisfy { $0.status == "completed" }
            let checksDone = checks.allSatisfy { $0.status == "completed" }
            let statusesDone = statuses.allSatisfy { $0.state != "pending" }
            if discovered && runsDone && checksDone && statusesDone { break }
            // A repository with no automatic checks must not remain stuck for the full run limit.
            if !discovered && poll >= 2 { return GitHubRunWatchResult(runs: [], checks: [], statuses: [], failedLogs: "") }
            try await sleeper()
        }
        var logText = ""
        for run in matched where !["success", "neutral", "skipped"].contains(run.conclusion ?? "") {
            if let archive = try? await github.workflowLogArchive(repo, runID: run.id) {
                logText += Self.readLogs(archive) + "\n"
            }
        }
        return GitHubRunWatchResult(runs: matched, checks: checks, statuses: statuses, failedLogs: logger.redact(String(logText.prefix(160_000))))
    }

    static func readLogs(_ data: Data) -> String {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("maipag-logs-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            try PreviewArtifactExtractor.extract(data, to: root)
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return "" }
            return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension.lowercased() == "txt" || $0.lastPathComponent.contains("_") }.compactMap { try? String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n")
        } catch { return "Workflow logs could not be unpacked." }
    }
}

public extension GitHubClient {
    /// Starts a workflow only when the caller has already decided the user's request asks for it.
    func dispatchWorkflow(_ repo: RepoRef, workflow: String, ref: String, inputs: [String: String] = [:]) async throws {
        let body: JSONValue = [
            "ref": .string(ref),
            "inputs": .object(inputs.mapValues(JSONValue.string)),
        ]
        _ = try await send("POST", Self.path(repo, "/actions/workflows/\(Self.escape(workflow))/dispatches"), body: body)
    }

    func workflowRuns(_ repo: RepoRef, workflow: String? = nil, branch: String? = nil, limit: Int = 30) async throws -> [GitHubWorkflowRun] {
        let suffix = workflow.map { "/actions/workflows/\(Self.escape($0))/runs" } ?? "/actions/runs"
        var query = ["per_page": String(min(max(limit, 1), 100))]
        if let branch { query["branch"] = branch }
        let response = try await send("GET", Self.path(repo, suffix), query: query)
        return try response.decode(WorkflowRunsPage.self).workflowRuns
    }

    func workflowRun(_ repo: RepoRef, runID: Int) async throws -> GitHubWorkflowRun {
        try await get(GitHubWorkflowRun.self, Self.path(repo, "/actions/runs/\(runID)"))
    }

    func workflowJobs(_ repo: RepoRef, runID: Int) async throws -> [GitHubWorkflowJob] {
        let response = try await send("GET", Self.path(repo, "/actions/runs/\(runID)/jobs"), query: ["per_page": "100"])
        return try response.decode(WorkflowJobsPage.self).jobs
    }

    func workflowLogArchive(_ repo: RepoRef, runID: Int) async throws -> Data {
        try await send("GET", Self.path(repo, "/actions/runs/\(runID)/logs"), accept: "application/vnd.github+json").body
    }

    func artifacts(_ repo: RepoRef, runID: Int? = nil) async throws -> [GitHubArtifact] {
        let suffix = runID.map { "/actions/runs/\($0)/artifacts" } ?? "/actions/artifacts"
        let response = try await send("GET", Self.path(repo, suffix), query: ["per_page": "100"])
        return try response.decode(ArtifactsPage.self).artifacts
    }

    func artifactArchive(_ repo: RepoRef, artifactID: Int) async throws -> Data {
        try await send("GET", Self.path(repo, "/actions/artifacts/\(artifactID)/zip"), accept: "application/octet-stream").body
    }

    func cancelWorkflowRun(_ repo: RepoRef, runID: Int) async throws {
        _ = try await send("POST", Self.path(repo, "/actions/runs/\(runID)/cancel"), allow: [409])
    }

    func checkRuns(_ repo: RepoRef, ref: String) async throws -> [GitHubCheckRun] {
        let response = try await send("GET", Self.path(repo, "/commits/\(Self.escapePath(ref))/check-runs"), accept: "application/vnd.github+json")
        return try response.decode(CheckRunsPage.self).checkRuns
    }

    func commitStatuses(_ repo: RepoRef, ref: String) async throws -> [GitHubCommitStatus] {
        try await get([GitHubCommitStatus].self, Self.path(repo, "/commits/\(Self.escapePath(ref))/statuses"))
    }

    func issueComments(_ repo: RepoRef, number: Int) async throws -> [JSONValue] {
        try await get([JSONValue].self, Self.path(repo, "/issues/\(number)/comments"))
    }

    @discardableResult
    func addPullRequestComment(_ repo: RepoRef, number: Int, body: String) async throws -> JSONValue {
        try await send("POST", Self.path(repo, "/issues/\(number)/comments"), body: ["body": .string(body)]).decode(JSONValue.self)
    }

    func pullRequestReviews(_ repo: RepoRef, number: Int) async throws -> [JSONValue] {
        try await get([JSONValue].self, Self.path(repo, "/pulls/\(number)/reviews"))
    }

    @discardableResult
    func addPullRequestReview(_ repo: RepoRef, number: Int, body: String, event: String = "COMMENT") async throws -> JSONValue {
        try await send("POST", Self.path(repo, "/pulls/\(number)/reviews"), body: ["body": .string(body), "event": .string(event)]).decode(JSONValue.self)
    }
}

private struct WorkflowRunsPage: Decodable { var workflowRuns: [GitHubWorkflowRun]; enum CodingKeys: String, CodingKey { case workflowRuns = "workflow_runs" } }
private struct WorkflowJobsPage: Decodable { var jobs: [GitHubWorkflowJob] }
private struct ArtifactsPage: Decodable { var artifacts: [GitHubArtifact] }
private struct CheckRunsPage: Decodable { var checkRuns: [GitHubCheckRun]; enum CodingKeys: String, CodingKey { case checkRuns = "check_runs" } }

public struct GitHubBuildReport: Sendable, Hashable {
    public var runs: [GitHubWorkflowRun]
    public var checks: [GitHubCheckRun]
    public var statuses: [GitHubCommitStatus]
    public var artifacts: [GitHubArtifact]
    public var release: GitHubRelease?

    public var failingChecks: [String] {
        checks.filter { $0.conclusion != nil && !["success", "neutral", "skipped"].contains($0.conclusion!) }.map(\.name)
    }

    public var ipaArtifact: GitHubArtifact? {
        artifacts.first { $0.name.lowercased().contains("ipa") && !$0.expired }
    }
}

public struct GitHubBuildInspector: Sendable {
    private let github: GitHubClient
    public init(github: GitHubClient) { self.github = github }

    /// Reads automatic checks and available IPA artifacts without starting any workflow.
    public func inspect(repo: RepoRef, ref: String) async throws -> GitHubBuildReport {
        async let runs = github.workflowRuns(repo, branch: ref)
        async let checks = github.checkRuns(repo, ref: ref)
        async let statuses = github.commitStatuses(repo, ref: ref)
        async let release = github.latestRelease(repo)
        let runValues = try await runs
        var artifactValues: [GitHubArtifact] = []
        if let run = runValues.first { artifactValues = (try? await github.artifacts(repo, runID: run.id)) ?? [] }
        return try await GitHubBuildReport(runs: runValues, checks: checks, statuses: statuses, artifacts: artifactValues, release: release)
    }

    /// The explicit flag prevents an inspection or ordinary job from accidentally dispatching a build.
    public func dispatch(repo: RepoRef, workflow: String, ref: String, explicitlyRequested: Bool) async throws {
        guard explicitlyRequested else { return }
        try await github.dispatchWorkflow(repo, workflow: workflow, ref: ref)
    }
}
