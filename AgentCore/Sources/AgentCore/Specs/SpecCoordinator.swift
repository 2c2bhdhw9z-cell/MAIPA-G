import Foundation

/// Durable ordered spec state plus the repository artifact writer.
public actor SpecCoordinator {
    private let store: ProductStore<SpecRecord>

    public init(dataDirectory: URL) {
        store = ProductStore(dataDirectory: dataDirectory, folder: "specs")
    }

    public func all() async -> [SpecRecord] { await store.loadAll() }
    public func load(_ id: UUID) async -> SpecRecord? { await store.load(id) }

    @discardableResult
    public func importExisting(repo: RepoRef, branch: String, defaultBranch: String, slug: String, requirements: String, design: String, tasksDocument: String) async throws -> SpecRecord {
        if let existing = await store.loadAll().first(where: { $0.repo == repo && $0.slug == slug }) { return existing }
        var record = SpecRecord(repo: repo, branch: branch, defaultBranch: defaultBranch, slug: slug, title: slug.replacingOccurrences(of: "-", with: " ").capitalized, stage: .execution)
        record.requirements = requirements
        record.design = design
        record.checkedDesign = design
        record.tasksDocument = tasksDocument
        record.tasks = Self.parseTasks(tasksDocument)
        record.approvedStages = [.requirements, .design, .checkedDesign, .tasks]
        if !record.tasks.isEmpty, record.tasks.allSatisfy(\.isComplete) { record.stage = .completed }
        try await store.save(record)
        return record
    }

    @discardableResult
    public func create(title: String, request: String, repo: RepoRef, branch: String, defaultBranch: String) async throws -> SpecRecord {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw SpecFailure.emptyTitle }
        let used = Set(await store.loadAll().filter { $0.repo == repo }.map(\.slug))
        let record = SpecRecord(
            repo: repo,
            branch: branch,
            defaultBranch: defaultBranch,
            slug: Self.uniqueSlug(clean, excluding: used),
            title: String(clean.prefix(100)),
            request: request.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        try await store.save(record)
        return record
    }

    @discardableResult
    public func updateArtifact(_ id: UUID, stage: SpecStage, text: String) async throws -> SpecRecord {
        guard var record = await store.load(id) else { throw SpecFailure.taskNotFound }
        guard record.stage == stage, [.requirements, .design, .checkedDesign, .tasks].contains(stage) else {
            throw SpecFailure.stageOutOfOrder(expected: record.stage, received: stage)
        }
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw SpecFailure.emptyArtifact(stage) }
        record.setArtifact(clean, for: stage)
        record.updatedAt = Date()
        try await store.save(record)
        return record
    }

    @discardableResult
    public func approve(_ id: UUID, stage: SpecStage) async throws -> SpecRecord {
        guard var record = await store.load(id) else { throw SpecFailure.taskNotFound }
        guard record.stage == stage else { throw SpecFailure.stageOutOfOrder(expected: record.stage, received: stage) }
        let artifact = record.artifact(for: stage).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !artifact.isEmpty else { throw SpecFailure.emptyArtifact(stage) }
        record.approvedStages.insert(stage)
        if stage == .tasks { record.tasks = Self.parseTasks(artifact) }
        record.stage = stage.next ?? .completed
        if record.stage == .execution, record.tasks.isEmpty { record.stage = .completed }
        record.updatedAt = Date()
        try await store.save(record)
        return record
    }

    @discardableResult
    public func setActiveJob(_ jobID: UUID?, for id: UUID, taskID: UUID? = nil) async throws -> SpecRecord {
        guard var record = await store.load(id) else { throw SpecFailure.taskNotFound }
        record.activeJobID = jobID
        record.activeTaskID = taskID
        record.updatedAt = Date()
        try await store.save(record)
        return record
    }

    @discardableResult
    public func attachSave(_ receipt: SaveReceipt, to id: UUID) async throws -> SpecRecord {
        guard var record = await store.load(id) else { throw SpecFailure.taskNotFound }
        record.saveReceipt = receipt
        record.updatedAt = Date()
        try await store.save(record)
        return record
    }

    @discardableResult
    public func completeTask(_ id: UUID, taskID: UUID) async throws -> SpecRecord {
        guard var record = await store.load(id), let index = record.tasks.firstIndex(where: { $0.id == taskID }) else { throw SpecFailure.taskNotFound }
        record.tasks[index].isComplete = true
        record.tasks[index].completedAt = Date()
        record.activeJobID = nil
        record.activeTaskID = nil
        if record.tasks.allSatisfy(\.isComplete) { record.stage = .completed }
        record.updatedAt = Date()
        try await store.save(record)
        return record
    }

    public func delete(_ id: UUID) async throws { try await store.delete(id) }

    /// Stages the three approved files together. Saving the overlay uses GitHubChangeService, so
    /// repo rules, direct-save, stale-head checks, and pull requests stay identical to chat saves.
    public func stageApprovedArtifacts(_ record: SpecRecord, in workspace: ChangeWorkspace) async throws {
        guard record.approvedStages.isSuperset(of: [.requirements, .design, .checkedDesign, .tasks]) else {
            throw SpecFailure.stageOutOfOrder(expected: record.stage, received: .tasks)
        }
        try await write(record.requirements, path: record.path(for: .requirements), in: workspace)
        try await write(record.checkedDesign, path: record.path(for: .design), in: workspace)
        try await write(record.tasksDocument, path: record.path(for: .tasks), in: workspace)
    }

    private func write(_ text: String, path: String, in workspace: ChangeWorkspace) async throws {
        switch try await workspace.read(path) {
        case .missing: try await workspace.create(path: path, text: text)
        case .text: try await workspace.edit(path: path, text: text)
        default: throw ChangeWorkspaceError.notText(path)
        }
    }

    public static func slug(_ value: String) -> String {
        let words = value.lowercased().map { $0.isLetter || $0.isNumber ? $0 : " " }.split(separator: " ")
        let result = String(words.prefix(8).joined(separator: "-"))
        return String((result.isEmpty ? "spec" : result).prefix(64))
    }

    public static func uniqueSlug(_ value: String, excluding used: Set<String>) -> String {
        let base = slug(value)
        guard used.contains(base) else { return base }
        var suffix = 2
        while used.contains("\(base)-\(suffix)") { suffix += 1 }
        return "\(base)-\(suffix)"
    }

    public static func parseTasks(_ markdown: String) -> [SpecTask] {
        markdown.components(separatedBy: .newlines).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let prefixes = ["- [ ] ", "* [ ] ", "- [x] ", "- [X] ", "* [x] ", "* [X] "]
            guard let prefix = prefixes.first(where: trimmed.hasPrefix) else { return nil }
            let title = String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            guard !title.isEmpty else { return nil }
            let done = prefix.lowercased().contains("[x]")
            return SpecTask(title: title, isComplete: done, completedAt: done ? Date() : nil)
        }
    }
}
