import AgentCore
import Foundation
import Observation

@MainActor
@Observable
final class JobCoordinator {
    private(set) var jobs: [JobRecord] = []
    private(set) var isRefreshing = false
    private(set) var lastError: String?
    private(set) var selectedJobID: UUID?

    @ObservationIgnored weak var app: AppModel?
    @ObservationIgnored private let store: JobStore
    @ObservationIgnored private var watcher: Task<Void, Never>?

    init(dataDirectory: URL) {
        store = JobStore(dataDirectory: dataDirectory)
    }

    deinit { watcher?.cancel() }

    var selectedJob: JobRecord? { jobs.first { $0.id == selectedJobID } }
    var activeCount: Int { jobs.filter { ![.done, .failed, .stopped].contains($0.status) }.count }

    func load() async {
        jobs = await store.all()
        startWatching()
    }

    func preview(_ records: [JobRecord]) {
        jobs = records
        selectedJobID = records.first?.id
    }

    func show(_ id: UUID? = nil) {
        selectedJobID = id ?? jobs.first?.id
        app?.sheet = .jobs
    }

    /// Repo-less work deliberately returns false and stays in the existing on-phone chat.
    func shouldRunAutonomously(request: String, repo: ChatRepo?, explicitlyEnabled: Bool) -> Bool {
        guard repo != nil, let app else { return false }
        if explicitlyEnabled { return true }
        switch app.settings.workflowPolicy {
        case .whenAsked: return false
        case .everything: return true
        case .bigJobs: return TaskDifficulty.estimate(request, hasRepo: true) == .hard
        }
    }

    @discardableResult
    func start(request: String, repo: ChatRepo) async -> JobRecord? {
        guard let app, let github = app.github.client else { return nil }
        let setup = AutonomousSetup(github: github)
        let installed = (try? await setup.isInstalled(in: repo.ref, ref: repo.defaultBranch)) == true
        var state: [String: JSONValue] = ["request": .string(request)]
        if let botName = app.github.credentials?.botName { state["botName"] = .string(botName) }
        if app.settings.spendLimitOn { state["spendLimit"] = .number(app.settings.spendLimit) }
        let question = JobQuestion(
            text: "Set up Autonomous in \(repo.ref.name)?",
            options: ["Set up and start", "Not now"],
            isApproval: true
        )
        let job = JobRecord(
            status: installed ? .queued : .needsApproval,
            title: ChatSession.provisionalTitle(request),
            state: .object(state),
            targetRepo: repo.ref,
            targetRef: repo.branch,
            defaultBranch: repo.defaultBranch,
            directSave: app.settings.savesDirectly(to: repo.ref),
            steps: [JobStepRecord(title: installed ? "Waiting for GitHub" : "Autonomous setup", status: installed ? .pending : .waiting)],
            questions: installed ? [] : [question]
        )
        do {
            _ = try await store.create(job)
            await reloadAndSync()
            selectedJobID = job.id
            app.sheet = .jobs
            if installed { try await dispatch(job) }
            return job
        } catch {
            lastError = app.github.describe(error)
            return nil
        }
    }

    /// Called only by the visible “Set up and start” button in Jobs.
    func confirmSetupAndStart(_ id: UUID) async {
        guard let app, let github = app.github.client, let credentials = app.github.credentials,
              let openRouterKey = app.openRouter.apiKey,
              var job = jobs.first(where: { $0.id == id }), let repo = job.targetRepo else { return }
        do {
            job.status = .settingUp
            job.steps = [JobStepRecord(title: "Setting up Autonomous", status: .running, startedAt: Date())]
            job.questions = []
            job = try await store.checkpoint(job)
            jobs = await store.all()
            let setup = AutonomousSetup(github: github)
            _ = try await setup.install(
                in: repo,
                branch: job.defaultBranch ?? "main",
                secrets: [
                    "MAIPAG_APP_ID": String(credentials.appID),
                    "MAIPAG_APP_PRIVATE_KEY": credentials.privateKeyPEM,
                    "OPENROUTER_API_KEY": openRouterKey,
                ]
            )
            job.status = .queued
            job.steps = [JobStepRecord(title: "Waiting for GitHub", status: .pending)]
            job = try await store.checkpoint(job)
            await reloadAndSync()
            try await dispatch(job)
        } catch {
            job.status = .failed
            job.result = JobResult(summary: "Autonomous setup didn't finish.")
            _ = try? await store.checkpoint(job)
            jobs = await store.all()
            lastError = app.github.describe(error)
        }
    }

    func answer(_ jobID: UUID, questionID: UUID, answer: String) async {
        guard let app else { return }
        do {
            if answer == "Set up and start" {
                await confirmSetupAndStart(jobID)
                return
            }
            if answer == "Not now" || answer == "Stop" {
                _ = try await store.stop(jobID)
            } else {
                let job = try await store.answer(jobID, questionID: questionID, answer: answer)
                await reloadAndSync()
                try await dispatch(job)
            }
            jobs = await store.all()
        } catch { lastError = app.github.describe(error) }
    }

    func stop(_ id: UUID) async {
        guard let app else { return }
        do {
            let job = try await store.stop(id)
            if let run = job.workflowRunID, let repo = job.targetRepo, let github = app.github.client {
                try? await github.cancelWorkflowRun(repo, runID: run)
            }
            await reloadAndSync()
        } catch { lastError = String(describing: error) }
    }

    func resume(_ id: UUID) async {
        guard let app else { return }
        do {
            let job = try await store.resume(id)
            await reloadAndSync()
            try await dispatch(job)
        } catch { lastError = app.github.describe(error) }
    }

    func addIt(_ id: UUID) async {
        guard let app, let github = app.github.client, var job = jobs.first(where: { $0.id == id }),
              let repo = job.targetRepo, let pull = job.result?.pullRequest else { return }
        do {
            try await github.mergePullRequest(repo, number: pull.number, title: pull.title)
            try await github.deleteBranch(repo, branch: pull.headBranch)
            job.result?.summary += "\n\nAdded the pull request and removed its side branch."
            job.result?.pullRequest = nil
            _ = try await store.checkpoint(job)
            await reloadAndSync()
        } catch { lastError = app.github.describe(error) }
    }

    func throwAway(_ id: UUID) async {
        guard let app, let github = app.github.client, var job = jobs.first(where: { $0.id == id }),
              let repo = job.targetRepo, let pull = job.result?.pullRequest else { return }
        do {
            _ = try await github.closePullRequest(repo, number: pull.number)
            try await github.deleteBranch(repo, branch: pull.headBranch)
            job.result?.summary += "\n\nClosed the pull request and removed its side branch."
            job.result?.pullRequest = nil
            _ = try await store.checkpoint(job)
            await reloadAndSync()
        } catch { lastError = app.github.describe(error) }
    }

    /// Builders must pass true only when the user's request expressly asks to start a build.
    func dispatchBuild(repo: RepoRef, workflow: String, ref: String, explicitlyRequested: Bool) async throws {
        guard explicitlyRequested, let github = app?.github.client else { return }
        try await github.dispatchWorkflow(repo, workflow: workflow, ref: ref)
    }

    func refresh() async {
        guard !isRefreshing, let app else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        await app.sync.syncNow()
        let before = Dictionary(uniqueKeysWithValues: jobs.map { ($0.id, $0.status) })
        jobs = await store.all()
        for job in jobs where before[job.id] != job.status && (job.status == .done || job.status == .needsAnswer || job.status == .needsApproval) {
            let needs = job.status == .needsAnswer || job.status == .needsApproval
            app.notifications.post(
                title: needs ? "MAIPA-G needs you" : "MAIPA-G finished",
                body: job.title,
                enabled: app.settings.notificationsOn
            )
        }
    }

    private func dispatch(_ job: JobRecord) async throws {
        guard let app, let github = app.github.client, let repo = job.targetRepo else { return }
        await app.sync.syncNow()
        try await github.dispatchWorkflow(
            repo,
            workflow: "maipa-g.yml",
            ref: job.defaultBranch ?? "main",
            inputs: ["job_id": job.id.uuidString.lowercased()]
        )
        var updated = job
        updated.status = .running
        updated.steps = [JobStepRecord(title: "Starting on GitHub", status: .running, startedAt: Date())]
        _ = try await store.checkpoint(updated)
        jobs = await store.all()
        app.sync.request()
    }

    private func reloadAndSync() async {
        jobs = await store.all()
        app?.sync.request(after: 0.1)
        await app?.sync.syncNow()
    }

    private func startWatching() {
        watcher?.cancel()
        watcher = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                guard !Task.isCancelled else { return }
                await self?.refresh()
            }
        }
    }
}
