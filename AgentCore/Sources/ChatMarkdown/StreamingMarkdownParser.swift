import Observation

/// Serial, off-main parsing for a live reply. Only the most recent document is retained;
/// incomplete drafts never fill the finished-message cache.
public actor StreamingMarkdownParser {
    private var source: String?
    private var document = MarkdownDocument(blocks: [])

    public init() {}

    public func parse(_ text: String) throws -> MarkdownDocument {
        // Superseded SwiftUI tasks can queue behind an expensive parse. Skip them.
        try Task.checkCancellation()
        if source != text {
            document = MarkdownDocument(parsing: text)
            source = text
        }
        return document
    }
}

/// A view-lifetime worker: finish the in-flight parse, publish it, then parse only
/// the newest pending source. Fast input must never starve a slow Markdown parse.
@MainActor
@Observable
public final class StreamingMarkdownWorker {
    public private(set) var document: MarkdownDocument?
    @ObservationIgnored private var pending: String?
    @ObservationIgnored private var latestSource: String?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private let parse: @Sendable (String) async throws -> MarkdownDocument
    @ObservationIgnored private(set) var task: Task<Void, Never>?

    public init() {
        let parser = StreamingMarkdownParser()
        parse = { try await parser.parse($0) }
    }

    // Injectable asynchronous parser lets tests hold a parse across many input updates.
    init(parse: @escaping @Sendable (String) async throws -> MarkdownDocument) {
        self.parse = parse
    }

    public func submit(_ text: String) {
        guard latestSource != text else { return }
        latestSource = text
        pending = text
        guard task == nil else { return }
        let currentGeneration = generation
        task = Task { [weak self] in
            guard let self else { return }
            while self.generation == currentGeneration, !Task.isCancelled,
                  let source = self.pending {
                self.pending = nil
                let parsed = try? await self.parse(source)
                guard self.generation == currentGeneration, !Task.isCancelled else { return }
                // Deliberately publish completed intermediate work even if input advanced.
                if let parsed { self.document = parsed }
            }
            guard self.generation == currentGeneration else { return }
            self.task = nil
        }
    }

    public func cancel() {
        generation &+= 1
        task?.cancel()
        task = nil
        pending = nil
        latestSource = nil
    }
}
