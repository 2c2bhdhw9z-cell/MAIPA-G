import Foundation

public struct DiagnosticEntry: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var at: Date
    public var area: String
    public var operation: String
    public var path: String?
    public var cause: String
    public var nextStep: String
    public var technical: String
    public var count: Int
}

private struct DiagnosticsDocument: Codable {
    var format = 1
    var installID: UUID
    var updatedAt: Date
    var entries: [DiagnosticEntry]
}

/// A small, redacted daily error log under data/diagnostics, so it follows the normal private
/// data-repository sync without ever triggering a sync recursively.
public actor DiagnosticsLog {
    private let dataDirectory: URL
    public let installID: UUID
    private let redactor: SensitiveDataRedactor

    public init(dataDirectory: URL, installIDURL: URL, secrets: [String] = []) {
        self.dataDirectory = dataDirectory
        redactor = SensitiveDataRedactor(secrets: secrets)
        if let text = try? String(contentsOf: installIDURL, encoding: .utf8), let saved = UUID(uuidString: text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            installID = saved
        } else {
            let value = UUID()
            installID = value
            try? FileManager.default.createDirectory(at: installIDURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? value.uuidString.lowercased().write(to: installIDURL, atomically: true, encoding: .utf8)
        }
    }

    public func record(error: Error, area: String, operation: String, path: String? = nil, now: Date = Date()) {
        let explanation = ErrorExplainer.explain(error)
        let file = url(for: now)
        var document = load(file) ?? DiagnosticsDocument(installID: installID, updatedAt: now, entries: [])
        let cause = redactor.redact(explanation.cause)
        let next = redactor.redact(explanation.nextStep)
        let technical = String(redactor.redact(explanation.technical).prefix(2_000))
        if let index = document.entries.lastIndex(where: {
            $0.area == area && $0.operation == operation && $0.path == path && $0.technical == technical && now.timeIntervalSince($0.at) < 600
        }) {
            document.entries[index].count += 1
            document.entries[index].at = now
        } else {
            document.entries.append(DiagnosticEntry(
                id: UUID(), at: now, area: area, operation: operation, path: path,
                cause: cause, nextStep: next, technical: technical, count: 1
            ))
        }
        document.updatedAt = now
        // Keep the newest bounded set; individual fields are already capped.
        if document.entries.count > 200 { document.entries.removeFirst(document.entries.count - 200) }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONCoding.encoder(pretty: true).encode(document).write(to: file, options: .atomic)
            prune(before: now.addingTimeInterval(-14 * 24 * 60 * 60))
        } catch {
            // Diagnostics must never cause a second failure or a save loop.
        }
    }

    public func recordMetricPayload(_ payload: Data, now: Date = Date()) {
        let digest = String(Hashing.sha256Hex(payload).prefix(12))
        let file = dataDirectory.appendingPathComponent(
            "diagnostics/\(installID.uuidString.lowercased())/metrickit/\(Int(now.timeIntervalSince1970))-\(digest).json"
        )
        guard !FileManager.default.fileExists(atPath: file.path), payload.count <= 1_000_000 else { return }
        let document: JSONValue = [
            "format": 1,
            "updatedAt": .string(ISO8601.string(from: now)),
            "payload": JSONValue.parse(payload) ?? .string(payload.base64EncodedString()),
        ]
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONCoding.encoder(pretty: true).encode(document).write(to: file, options: .atomic)
        } catch {
            // Metric reporting must never affect app startup.
        }
    }

    public func recentEntries() -> [DiagnosticEntry] {
        let folder = dataDirectory.appendingPathComponent("diagnostics/\(installID.uuidString.lowercased())", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.compactMap(load).flatMap(\.entries).sorted { $0.at > $1.at }
    }

    private func url(for date: Date) -> URL {
        let day = String(ISO8601.string(from: date).prefix(10))
        return dataDirectory.appendingPathComponent("diagnostics/\(installID.uuidString.lowercased())/errors-\(day).json")
    }

    private func load(_ url: URL) -> DiagnosticsDocument? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONCoding.decoder().decode(DiagnosticsDocument.self, from: data)
    }

    private func prune(before cutoff: Date) {
        let folder = dataDirectory.appendingPathComponent("diagnostics/\(installID.uuidString.lowercased())", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for file in files {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantFuture
            if modified < cutoff { try? FileManager.default.removeItem(at: file) }
        }
    }
}
