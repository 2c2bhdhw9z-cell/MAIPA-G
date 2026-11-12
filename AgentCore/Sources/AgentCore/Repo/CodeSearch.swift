import Foundation

public struct SearchQuery: Sendable, Hashable {
    public var pattern: String
    public var isRegex: Bool
    public var caseSensitive: Bool
    public var pathGlob: String?
    public var maxResults: Int
    public var maxPerFile: Int
    /// Lines shown before and after each match, like `grep -C`.
    public var contextLines: Int
    /// Files (or folders) whose path matches this pattern are left out.
    public var excludeGlob: String?

    public init(pattern: String, isRegex: Bool = false, caseSensitive: Bool = false, pathGlob: String? = nil, maxResults: Int = 80, maxPerFile: Int = 12, contextLines: Int = 0, excludeGlob: String? = nil) {
        self.pattern = pattern
        self.isRegex = isRegex
        self.caseSensitive = caseSensitive
        self.pathGlob = pathGlob
        self.maxResults = maxResults
        self.maxPerFile = maxPerFile
        self.contextLines = max(0, contextLines)
        self.excludeGlob = excludeGlob
    }
}

/// A line next to a match, shown for context.
public struct SearchContextLine: Sendable, Hashable {
    public var line: Int
    public var text: String
}

public struct SearchMatch: Sendable, Hashable {
    public var path: String
    public var line: Int
    /// The matching line with its indentation; very long lines end with "[truncated: line too long]".
    public var text: String
    public var contextBefore: [SearchContextLine] = []
    public var contextAfter: [SearchContextLine] = []
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
/// that contain a match are split into lines. Files are searched in parallel. Line numbers are
/// counted the way read_file counts them.
public enum CodeSearch {
    static let maxLineLength = 500
    static let longLineMarker = " [truncated: line too long]"

    public static func run(_ query: SearchQuery, in snapshot: RepoSnapshot, stagedChanges: [StagedChange] = []) async throws -> SearchResult {
        let pattern = query.pattern
        guard !pattern.isEmpty else { throw SearchError.emptyPattern }
        let matcher = try Matcher(query)
        let glob = query.pathGlob.flatMap { $0.isEmpty ? nil : Glob($0) }
        let exclude = query.excludeGlob.flatMap { $0.isEmpty ? nil : Glob($0) }
        let stagedPaths = Set(stagedChanges.map(\.path))
        func wanted(_ path: String) -> Bool {
            (glob.map { $0.matches(path) } ?? true) && !(exclude.map { isExcluded(path, by: $0) } ?? false)
        }

        let candidates = snapshot.manifest.files.filter { file in
            !stagedPaths.contains(file.path) && wanted(file.path)
        }
        let searchable = candidates.filter { $0.kind == .text }
        let skipped = candidates.count - searchable.count

        let workers = max(2, min(8, ProcessInfo.processInfo.activeProcessorCount))
        let chunkSize = max(1, (searchable.count + workers - 1) / workers)
        let chunks = stride(from: 0, to: searchable.count, by: chunkSize).map { Array(searchable[$0..<min($0 + chunkSize, searchable.count)]) }

        let perFileCap = query.maxPerFile
        let context = query.contextLines
        var fileMatches: [(path: String, matches: [SearchMatch], total: Int)] = try await withThrowingTaskGroup(of: [(String, [SearchMatch], Int)].self) { group in
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
                        let (matches, total) = Self.matches(in: text, path: file.path, matcher: matcher, perFileCap: perFileCap, context: context)
                        if total > 0 { found.append((file.path, matches, total)) }
                    }
                    return found
                }
            }
            var all: [(path: String, matches: [SearchMatch], total: Int)] = []
            for try await batch in group {
                all += batch.map { (path: $0.0, matches: $0.1, total: $0.2) }
            }
            return all
        }

        var stagedSearched = 0
        for change in stagedChanges {
            guard case .write(let path, let data, _) = change,
                  wanted(path),
                  let document = TextFileCodec.decode(data)
            else { continue }
            stagedSearched += 1
            let text = document.text
            guard matcher.matchesAnywhere(text) else { continue }
            let (matches, total) = Self.matches(in: text, path: path, matcher: matcher, perFileCap: perFileCap, context: context)
            if total > 0 { fileMatches.append((path: path, matches: matches, total: total)) }
        }
        fileMatches.sort { $0.path < $1.path }

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
            filesSearched: searchable.count + stagedSearched,
            filesMatched: fileMatches.count,
            truncated: truncated,
            filesSkipped: skipped
        )
    }

    /// The matching lines of one file (at most `perFileCap`, each with `context` lines around it)
    /// and how many lines matched in all.
    static func matches(in text: String, path: String, matcher: Matcher, perFileCap: Int, context: Int) -> ([SearchMatch], Int) {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.last == "" { lines.removeLast() }
        var matches: [SearchMatch] = []
        var total = 0
        for index in lines.indices where matcher.matches(String(lines[index])) {
            total += 1
            guard matches.count < perFileCap else { continue }
            var match = SearchMatch(path: path, line: index + 1, text: trimmed(String(lines[index])))
            if context > 0 {
                match.contextBefore = (max(0, index - context)..<index).map { SearchContextLine(line: $0 + 1, text: trimmed(String(lines[$0]))) }
                match.contextAfter = (index + 1..<min(lines.count, index + 1 + context)).map { SearchContextLine(line: $0 + 1, text: trimmed(String(lines[$0]))) }
            }
            matches.append(match)
        }
        return (matches, total)
    }

    /// Whether `path`, or any folder it is in, matches `glob`: "node_modules" leaves out every
    /// node_modules folder, "*.min.js" every minified file, "docs/**" everything under docs.
    public static func isExcluded(_ path: String, by glob: Glob) -> Bool {
        if glob.matches(path) { return true }
        let parts = path.split(separator: "/")
        guard parts.count > 1 else { return false }
        for end in 1..<parts.count where glob.matches(parts[0..<end].joined(separator: "/")) { return true }
        return false
    }

    /// The line as it is, indentation kept; only a trailing carriage return or spaces go, and a
    /// very long line is shortened with a clear mark.
    static func trimmed(_ line: String) -> String {
        var clean = line
        while let last = clean.last, last == "\r" || last == " " || last == "\t" { clean.removeLast() }
        guard clean.count > maxLineLength else { return clean }
        return String(clean.prefix(maxLineLength)) + longLineMarker
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
