import Foundation
import ZIPFoundation

public enum GitHubCheckDiscovery: String, Sendable, Hashable {
    case observed, confirmedNoChecks, timedOut
}

public struct GitHubRunWatchResult: Sendable, Hashable {
    public var runs: [GitHubWorkflowRun]
    public var checks: [GitHubCheckRun]
    public var statuses: [GitHubCommitStatus]
    public var failedLogs: String
    public var discovery: GitHubCheckDiscovery

    public var succeeded: Bool {
        if discovery == .confirmedNoChecks { return true }
        guard discovery == .observed, !runs.isEmpty || !checks.isEmpty || !statuses.isEmpty else { return false }
        return runs.allSatisfy { ["success", "neutral", "skipped"].contains($0.conclusion ?? "") }
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

    /// How long to look for checks to appear at all. GitHub starts runs within seconds of a push;
    /// workflows filtered by branch or path never start, and that must not read as passed or failed.
    private let discoveryPolls: Int

    public init(github: GitHubClient, maximumPolls: Int = 90, discoveryPolls: Int = 15, sleeper: @escaping Sleeper = {
        try await Task.sleep(nanoseconds: 20_000_000_000)
    }) {
        self.github = github; self.maximumPolls = max(1, maximumPolls); self.sleeper = sleeper
        self.discoveryPolls = max(1, min(discoveryPolls, self.maximumPolls))
    }

    public func wait(repo: RepoRef, commit: String, branch: String = "main", excludingRunID: Int? = nil, redacting logger: RedactingLogger) async throws -> GitHubRunWatchResult {
        var matched: [GitHubWorkflowRun] = []
        var checks: [GitHubCheckRun] = []
        var statuses: [GitHubCommitStatus] = []
        var discovery: GitHubCheckDiscovery = .timedOut
        var expectsChecks: Bool?
        for poll in 0..<maximumPolls {
            matched = try await github.workflowRuns(repo, limit: 100).filter { $0.headSHA == commit && $0.id != excludingRunID }
            checks = (try? await github.checkRuns(repo, ref: commit)) ?? []
            statuses = (try? await github.commitStatuses(repo, ref: commit)) ?? []
            let discovered = !matched.isEmpty || !checks.isEmpty || !statuses.isEmpty
            let runsDone = matched.allSatisfy { $0.status == "completed" }
            let checksDone = checks.allSatisfy { $0.status == "completed" }
            let statusesDone = statuses.allSatisfy { $0.state != "pending" }
            if discovered {
                discovery = .observed
                if runsDone && checksDone && statusesDone { break }
            } else if poll >= 2 {
                if expectsChecks == nil { expectsChecks = try await github.expectsAutomaticChecks(repo, commit: commit, branch: branch) }
                if expectsChecks == false {
                    return GitHubRunWatchResult(runs: [], checks: [], statuses: [], failedLogs: "", discovery: .confirmedNoChecks)
                }
                // Nothing started in the discovery window: report that honestly (not passed, not failed).
                if poll + 1 >= discoveryPolls {
                    return GitHubRunWatchResult(runs: [], checks: [], statuses: [], failedLogs: "", discovery: .timedOut)
                }
            }
            if poll + 1 < maximumPolls { try await sleeper() }
        }
        var logText = ""
        for run in matched where !["success", "neutral", "skipped"].contains(run.conclusion ?? "") {
            if let archive = try? await github.workflowLogArchive(repo, runID: run.id) {
                logText += Self.readLogs(archive) + "\n"
            }
        }
        return GitHubRunWatchResult(runs: matched, checks: checks, statuses: statuses, failedLogs: logger.redact(String(logText.prefix(160_000))), discovery: discovery)
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

    /// Positively identifies repositories where this commit cannot have automatic Actions or
    /// required status checks. Unknown workflow syntax is treated as expected work, never success.
    func expectsAutomaticChecks(_ repo: RepoRef, commit: String, branch: String) async throws -> Bool {
        let protection = try await send(
            "GET", Self.path(repo, "/branches/\(Self.escapePath(branch))/protection/required_status_checks"),
            allow: [404]
        )
        if protection.status != 404, let value = JSONValue.parse(protection.body) {
            let contexts = value["contexts"]?.arrayValue ?? []
            let checks = value["checks"]?.arrayValue ?? []
            if !contexts.isEmpty || !checks.isEmpty { return true }
        }

        let listing = try await send(
            "GET", Self.path(repo, "/contents/.github/workflows"),
            query: ["ref": commit], allow: [404]
        )
        guard listing.status != 404, let entries = JSONValue.parse(listing.body)?.arrayValue else { return false }
        for entry in entries {
            guard let path = entry["path"]?.stringValue,
                  ["yml", "yaml"].contains(URL(fileURLWithPath: path).pathExtension.lowercased()) else { continue }
            guard let data = try? await fileContents(repo, path: path, ref: commit),
                  let yaml = String(data: data, encoding: .utf8) else { return true }
            let normalized = yaml.lowercased().replacingOccurrences(of: "\r\n", with: "\n")
            if normalized.range(of: #"(?m)^\s*(push|pull_request|pull_request_target|merge_group)\s*:"#, options: .regularExpression) != nil
                || normalized.range(of: #"(?m)^\s*["']?on["']?\s*:\s*\[[^\]]*(push|pull_request|merge_group)"#, options: .regularExpression) != nil
                || normalized.range(of: #"(?m)^\s*["']?on["']?\s*:\s*["']?(push|pull_request|pull_request_target|merge_group)["']?\s*$"#, options: .regularExpression) != nil
                || normalized.range(of: #"(?m)^\s*-\s*(push|pull_request|pull_request_target|merge_group)\s*$"#, options: .regularExpression) != nil {
                return true
            }
        }
        return false
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


public struct GitHubActionsBilling: Codable, Sendable, Hashable {
    public var totalMinutesUsed: Double
    public var totalPaidMinutesUsed: Double
    public var includedMinutes: Double
    public var minutesUsedBreakdown: [String: Double]

    enum CodingKeys: String, CodingKey {
        case totalMinutesUsed = "total_minutes_used"
        case totalPaidMinutesUsed = "total_paid_minutes_used"
        case includedMinutes = "included_minutes"
        case minutesUsedBreakdown = "minutes_used_breakdown"
    }

    public var includedMinutesRemaining: Int {
        max(0, Int((includedMinutes - totalMinutesUsed).rounded(.down)))
    }
}

public extension GitHubClient {
    func actionsBilling(for user: String) async throws -> GitHubActionsBilling {
        try await get(GitHubActionsBilling.self, "/users/\(Self.escape(user))/settings/billing/actions", auth: .user)
    }
}
