import AgentCore
import Foundation
import Observation

@MainActor
@Observable
final class SpecCoordinator {
    private(set) var specs: [SpecRecord] = []
    private(set) var isLoading = false
    private(set) var lastError: String?

    @ObservationIgnored weak var app: AppModel?
    @ObservationIgnored private let core: AgentCore.SpecCoordinator

    init(dataDirectory: URL) {
        core = AgentCore.SpecCoordinator(dataDirectory: dataDirectory)
    }

    func load(discovering repo: ChatRepo? = nil) async {
        guard !PreviewScenes.isActive else { return }
        if let repo { await discover(in: repo) }
        specs = await core.all()
    }

    func preview(_ values: [SpecRecord]) { specs = values }

    @discardableResult
    func create(title: String, request: String, repo: ChatRepo) async -> SpecRecord? {
        do {
            let record = try await core.create(title: title, request: request, repo: repo.ref, branch: repo.branch, defaultBranch: repo.defaultBranch)
            specs = await core.all()
            await draft(record)
            return record
        } catch { lastError = ErrorExplainer.explain(error).message; return nil }
    }

    func draft(_ record: SpecRecord) async {
        guard let app else { return }
        let context = context(for: record)
        let workflow = SpecWorkflows.draft(record.stage, context: context)
        let specRepo = ChatRepo(
            ref: record.repo,
            branch: record.branch,
            defaultBranch: record.defaultBranch,
            isPrivate: app.github.repo(named: record.repo.fullName)?.isPrivate ?? false
        )
        guard let job = await app.jobs.start(workflow: workflow, request: record.request, repo: nil, readOnlyRepo: specRepo, openJobsSheet: false) else {
            lastError = "Couldn't start the \(record.stage.title.lowercased())."
            return
        }
        do { _ = try await core.setActiveJob(job.id, for: record.id); specs = await core.all() }
        catch { lastError = ErrorExplainer.explain(error).message }
    }

    func saveArtifact(_ record: SpecRecord, stage: SpecStage, text: String) async -> SpecRecord? {
        do { let saved = try await core.updateArtifact(record.id, stage: stage, text: text); specs = await core.all(); app?.sync.request(); return saved }
        catch { lastError = ErrorExplainer.explain(error).message; return nil }
    }

    func approve(_ record: SpecRecord, text: String) async {
        guard let saved = await saveArtifact(record, stage: record.stage, text: text) else { return }
        do {
            let advanced = try await core.approve(saved.id, stage: saved.stage)
            specs = await core.all()
            app?.sync.request()
            if advanced.stage == .execution { await saveApprovedArtifacts(advanced) }
            else if advanced.stage != .completed { await draft(advanced) }
        } catch { lastError = ErrorExplainer.explain(error).message }
    }

    func execute(_ task: SpecTask, in record: SpecRecord) async {
        guard let app else { return }
        let workflow = SpecWorkflows.execute(task: task, context: context(for: record))
        let workingBranch: String
        if let receipt = record.saveReceipt, receipt.pullRequest != nil, receipt.resolution == nil {
            workingBranch = receipt.branch
        } else {
            workingBranch = record.branch
        }
        let repo = ChatRepo(ref: record.repo, branch: workingBranch, defaultBranch: record.defaultBranch, isPrivate: app.github.repo(named: record.repo.fullName)?.isPrivate ?? false)
        guard let job = await app.jobs.start(workflow: workflow, request: task.title, repo: repo) else { return }
        do { _ = try await core.setActiveJob(job.id, for: record.id, taskID: task.id); specs = await core.all() }
        catch { lastError = ErrorExplainer.explain(error).message }
    }

    func refreshJobs() async {
        guard let app else { return }
        for record in specs {
            guard let jobID = record.activeJobID, let job = app.jobs.jobs.first(where: { $0.id == jobID }) else { continue }
            switch job.status {
            case .done:
                do {
                    if let taskID = record.activeTaskID {
                        if job.result?.verificationPassed == true {
                            _ = try await core.completeTask(record.id, taskID: taskID)
                        } else {
                            lastError = "The task check still found unresolved defects. The task remains open."
                            _ = try await core.setActiveJob(nil, for: record.id)
                        }
                    } else if let output = job.result?.summary, !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        _ = try await core.updateArtifact(record.id, stage: record.stage, text: output)
                        _ = try await core.setActiveJob(nil, for: record.id)
                    }
                } catch { lastError = ErrorExplainer.explain(error).message }
            case .failed, .stopped:
                lastError = job.result?.summary ?? "The spec step didn't finish."
                _ = try? await core.setActiveJob(nil, for: record.id)
            default: break
            }
        }
        specs = await core.all()
        app.sync.request()
    }

    func addIt(_ record: SpecRecord) async {
        guard let app, let github = app.github.client, var receipt = record.saveReceipt, receipt.pullRequest != nil, receipt.resolution == nil else { return }
        do {
            try await GitHubChangeService(github: github).addIt(receipt)
            receipt.resolution = "added"
            _ = try await core.attachSave(receipt, to: record.id)
            specs = await core.all()
            app.sync.request()
        } catch { lastError = app.github.describe(error) }
    }

    func throwAway(_ record: SpecRecord) async {
        guard let app, let github = app.github.client, var receipt = record.saveReceipt, receipt.pullRequest != nil, receipt.resolution == nil else { return }
        do {
            try await GitHubChangeService(github: github).throwAway(receipt)
            receipt.resolution = "discarded"
            _ = try await core.attachSave(receipt, to: record.id)
            specs = await core.all()
            app.sync.request()
        } catch { lastError = app.github.describe(error) }
    }

    func delete(_ id: UUID) async {
        do { try await core.delete(id); specs = await core.all(); app?.sync.request() }
        catch { lastError = ErrorExplainer.explain(error).message }
    }

    private func saveApprovedArtifacts(_ record: SpecRecord) async {
        guard let app, let github = app.github.client else { lastError = "Connect GitHub first."; return }
        isLoading = true
        defer { isLoading = false }
        do {
            let commit = try await github.resolveCommit(record.repo, ref: record.branch)
            let repoWorkspace = RepoWorkspace(repo: record.repo, branch: record.branch, commit: commit, github: github, store: app.snapshots)
            let workspace = ChangeWorkspace(base: repoWorkspace)
            try await core.stageApprovedArtifacts(record, in: workspace)
            let service = GitHubChangeService(github: github)
            let rules = await service.resolveRules(in: repoWorkspace, directSaveSetting: app.settings.savesDirectly(to: record.repo))
            let receipt = try await service.save(workspace, selectedBranch: record.branch, defaultBranch: record.defaultBranch, rules: rules, title: "Add \(record.title) spec", body: "Approved requirements, checked design, and tasks from MAIPA-G.")
            _ = try await core.attachSave(receipt, to: record.id)
            specs = await core.all()
            app.sync.request()
        } catch { lastError = app.github.describe(error) }
    }

    private func discover(in repo: ChatRepo) async {
        guard let app, let github = app.github.client else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let commit = try await github.resolveCommit(repo.ref, ref: repo.branch)
            let workspace = RepoWorkspace(repo: repo.ref, branch: repo.branch, commit: commit, github: github, store: app.snapshots)
            let paths = try await workspace.tree().entries.filter { $0.isFile && $0.path.hasPrefix(".kiro/specs/") }
            let slugs = Set(paths.compactMap { entry -> String? in
                let parts = entry.path.split(separator: "/")
                return parts.count >= 4 ? String(parts[2]) : nil
            })
            for slug in slugs {
                let requirements = await text(".kiro/specs/\(slug)/requirements.md", in: workspace)
                let design = await text(".kiro/specs/\(slug)/design.md", in: workspace)
                let tasks = await text(".kiro/specs/\(slug)/tasks.md", in: workspace)
                guard !requirements.isEmpty, !design.isEmpty, !tasks.isEmpty else { continue }
                _ = try await core.importExisting(repo: repo.ref, branch: repo.branch, defaultBranch: repo.defaultBranch, slug: slug, requirements: requirements, design: design, tasksDocument: tasks)
            }
        } catch { lastError = app.github.describe(error) }
    }

    private func text(_ path: String, in workspace: RepoWorkspace) async -> String {
        guard case .text(let value, _) = try? await workspace.readFile(path) else { return "" }
        return value
    }

    private func context(for record: SpecRecord) -> String {
        [
            "Project: \(record.repo.fullName)",
            "Spec folder: .kiro/specs/\(record.slug)/",
            record.request.isEmpty ? "" : "Request:\n\(record.request)",
            record.requirements.isEmpty ? "" : "Approved requirements:\n\(record.requirements)",
            record.checkedDesign.isEmpty ? (record.design.isEmpty ? "" : "Design:\n\(record.design)") : "Approved checked design:\n\(record.checkedDesign)",
            record.tasksDocument.isEmpty ? "" : "Approved tasks:\n\(record.tasksDocument)",
        ].filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
}
