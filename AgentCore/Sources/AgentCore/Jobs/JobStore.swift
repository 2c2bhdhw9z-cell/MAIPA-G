import Foundation

/// Persistent job state used by both the phone and the cloud runner.
public actor JobStore {
    private let records: ProductStore<JobRecord>

    public init(dataDirectory: URL) {
        records = ProductStore(dataDirectory: dataDirectory, folder: "jobs")
    }

    public func all() async -> [JobRecord] { await records.loadAll() }
    public func load(_ id: UUID) async -> JobRecord? { await records.load(id) }

    @discardableResult
    public func create(_ job: JobRecord) async throws -> JobRecord {
        try await records.save(job)
        return job
    }

    @discardableResult
    public func checkpoint(_ job: JobRecord, at date: Date = Date()) async throws -> JobRecord {
        var copy = job
        copy.format = JobRecord.currentFormat
        copy.updatedAt = date
        try await records.save(copy)
        return copy
    }

    @discardableResult
    public func update(_ id: UUID, _ change: (inout JobRecord) throws -> Void) async throws -> JobRecord {
        guard var job = await records.load(id) else { throw JobStoreError.notFound }
        try change(&job)
        job.format = JobRecord.currentFormat
        job.updatedAt = Date()
        try await records.save(job)
        return job
    }

    public func stop(_ id: UUID) async throws -> JobRecord {
        try await update(id) { job in
            job.status = .stopped
            for index in job.steps.indices where job.steps[index].status == .running {
                job.steps[index].status = .stopped
                job.steps[index].finishedAt = Date()
            }
        }
    }

    public func resume(_ id: UUID) async throws -> JobRecord {
        try await update(id) { job in
            job.status = .queued
            job.questions.removeAll { $0.answer != nil }
        }
    }

    public func answer(_ id: UUID, questionID: UUID, answer: String) async throws -> JobRecord {
        try await update(id) { job in
            guard let index = job.questions.firstIndex(where: { $0.id == questionID }) else {
                throw JobStoreError.questionNotFound
            }
            job.questions[index].answer = answer
            job.status = .queued
        }
    }
}

public enum JobStoreError: Error, Sendable, Equatable {
    case notFound
    case questionNotFound
}
