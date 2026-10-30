import Foundation

public struct SearchQuery: Sendable, Hashable {
    public var pattern: String
    public var isRegex: Bool
    public var caseSensitive: Bool
    public var pathGlob: String?
    public var maxResults: Int
    public var maxPerFile: Int

    public init(pattern: String, isRegex: Bool = false, caseSensitive: Bool = false, pathGlob: String? = nil, maxResults: Int = 80, maxPerFile: Int = 12) {
        self.pattern = pattern
        self.isRegex = isRegex
        self.caseSensitive = caseSensitive
        self.pathGlob = pathGlob
        self.maxResults = maxResults
        self.maxPerFile = maxPerFile
    }
}

public struct SearchMatch: Sendable, Hashable {
    public var path: String
    public var line: Int
    public var text: String
}

public struct SearchResult: Sendable {
    public var matches: [SearchMatch]
    public var filesSearched: Int
    public var filesMatched: Int
    /// More matches exist than were returned.
    public var truncated: Bool
    /// Files that could not be searched (pictures, archives, very large files).
    public var filesSkipped: Int
}

public enum SearchError: Error, Sendable, CustomStringConvertible {
    case badPattern(String)
    case emptyPattern

    public var description: String {
        switch self {
        case .badPattern(let detail): return "That search pattern is not valid: \(detail)"
        case .emptyPattern: return "The search pattern is empty"
        }
    }
}

/// Searches the text files of a local repo copy, like a small grep.
///
/// Each file is first checked as a whole, which rules out most files in one fast pass; only files
/// that contain a match are split into lines. Files are searched in parallel.
public enum CodeSearch {
    static let maxLineLength = 240

    public static func run(_ query: SearchQuery, in snapshot: RepoSnapshot) async throws -> SearchResult {
        let pattern = query.pattern
        guard !pattern.isEmpty else { throw SearchError.emptyPattern }
        let matcher = try Matcher(query)
        let glob = query.pathGlob.flatMap { $0.isEmpty ? nil : Glob($0) }

        let candidates = snapshot.manifest.files.filter { file in
            glob.map { $0.matches(file.path) } ?? true
        }
        let searchable = candidates.filter { $0.kind == .text }
        let skipped = candidates.count - searchable.count

        let workers = max(2, min(8, ProcessInfo.processInfo.activeProcessorCount))
        let chunkSize = max(1, (searchable.count + workers - 1) / workers)
        let chunks = stride(from: 0, to: searchable.count, by: chunkSize).map { Array(searchable[$0..<min($0 + chunkSize, searchable.count)]) }

        let perFileCap = query.maxPerFile
        let fileMatches: [(path: String, matches: [SearchMatch], total: Int)] = try await withThrowingTaskGroup(of: [(String, [SearchMatch], Int)].self) { group in
            for chunk in chunks {
                group.addTask {
                    var found: [(String, [SearchMatch], Int)] = []
                    for file in chunk {
                        try Task.checkCancellation()
                        guard let data = snapshot.contents(of: file.path),
                              let document = TextFileCodec.decode(data)
                        else { continue }
                        let text = document.text
                        guard matcher.matchesAnywhere(text) else { continue }
                        var matches: [SearchMatch] = []
                        var total = 0
                        var lineNumber = 0
                        text.enumerateLines { line, _ in
                            lineNumber += 1
                            if matcher.matches(line) {
                                total += 1
                                if matches.count < perFileCap {
                                    matches.append(SearchMatch(path: file.path, line: lineNumber, text: Self.trimmed(line)))
                                }
                            }
                        }
                        if total > 0 { found.append((file.path, matches, total)) }
                    }
                    return found
                }
            }
            var all: [(path: String, matches: [SearchMatch], total: Int)] = []
            for try await batch in group {
                all += batch.map { (path: $0.0, matches: $0.1, total: $0.2) }
            }
            return all.sorted { $0.path < $1.path }
        }

        var matches: [SearchMatch] = []
        var truncated = false
        for file in fileMatches {
            if file.total > file.matches.count { truncated = true }
            for match in file.matches {
                if matches.count >= query.maxResults {
                    truncated = true
                    break
                }
                matches.append(match)
            }
        }
        return SearchResult(
            matches: matches,
            filesSearched: searchable.count,
            filesMatched: fileMatches.count,
            truncated: truncated,
            filesSkipped: skipped
        )
    }

    static func trimmed(_ line: String) -> String {
        let clean = line.trimmingCharacters(in: .whitespaces)
        guard clean.count > maxLineLength else { return clean }
        return String(clean.prefix(maxLineLength)) + "…"
    }

    /// A compiled search, shared read-only between the worker tasks.
    struct Matcher: @unchecked Sendable {
        private let literal: String?
        private let options: String.CompareOptions
        private let regex: NSRegularExpression?

        init(_ query: SearchQuery) throws {
            if query.isRegex {
                do {
                    var options: NSRegularExpression.Options = [.anchorsMatchLines]
                    if !query.caseSensitive { options.insert(.caseInsensitive) }
                    regex = try NSRegularExpression(pattern: query.pattern, options: options)
                } catch {
                    throw SearchError.badPattern(error.localizedDescription)
                }
                literal = nil
                self.options = []
            } else {
                regex = nil
                literal = query.pattern
                options = query.caseSensitive ? [.literal] : [.literal, .caseInsensitive]
            }
        }

        func matchesAnywhere(_ text: String) -> Bool {
            matches(text)
        }

        func matches(_ text: String) -> Bool {
            if let literal {
                return text.range(of: literal, options: options) != nil
            }
            guard let regex else { return false }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            return regex.firstMatch(in: text, options: [], range: range) != nil
        }
    }
}
