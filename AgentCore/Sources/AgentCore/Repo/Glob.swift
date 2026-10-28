import Foundation

/// File-name patterns like `*.swift`, `src/**/*.ts` or `{App,Tests}/**`.
///
/// `*` matches within one folder name, `**` matches across folders, `?` matches one character,
/// `[abc]` and `[a-z]` match one of a set, and `{a,b}` matches either alternative. A pattern
/// without a slash is matched against the file name alone, so `*.md` finds Markdown anywhere.
public struct Glob: Sendable, Hashable {
    public let pattern: String
    private let alternatives: [[Token]]
    private let matchesNameOnly: Bool

    enum Token: Hashable, Sendable {
        case literal(Character)
        case any // ?
        case star // *
        case globstar // **
        case set([ClosedRange<Character>], negated: Bool)
    }

    public init(_ pattern: String) {
        self.pattern = pattern
        let trimmed = pattern.hasPrefix("./") ? String(pattern.dropFirst(2)) : pattern
        matchesNameOnly = !trimmed.contains("/")
        alternatives = Self.expandBraces(trimmed).map(Self.tokenize)
    }

    public func matches(_ path: String) -> Bool {
        let subject: String
        if matchesNameOnly {
            subject = path.split(separator: "/").last.map(String.init) ?? path
        } else {
            subject = path
        }
        let characters = Array(subject)
        return alternatives.contains { Self.match($0[...], characters[...]) }
    }

    static func expandBraces(_ pattern: String) -> [String] {
        guard let open = pattern.firstIndex(of: "{") else { return [pattern] }
        var depth = 0
        var close: String.Index?
        var index = open
        while index < pattern.endIndex {
            if pattern[index] == "{" { depth += 1 }
            if pattern[index] == "}" {
                depth -= 1
                if depth == 0 { close = index; break }
            }
            index = pattern.index(after: index)
        }
        guard let close else { return [pattern] }
        let prefix = String(pattern[..<open])
        let suffix = String(pattern[pattern.index(after: close)...])
        let inner = pattern[pattern.index(after: open)..<close]
        var options: [String] = []
        var current = ""
        depth = 0
        for character in inner {
            if character == "," && depth == 0 {
                options.append(current)
                current = ""
                continue
            }
            if character == "{" { depth += 1 }
            if character == "}" { depth -= 1 }
            current.append(character)
        }
        options.append(current)
        return options.flatMap { expandBraces(prefix + $0 + suffix) }
    }

    static func tokenize(_ pattern: String) -> [Token] {
        var tokens: [Token] = []
        let characters = Array(pattern)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            switch character {
            case "*":
                if index + 1 < characters.count, characters[index + 1] == "*" {
                    tokens.append(.globstar)
                    index += 2
                    // "**/" also matches no folders at all.
                    if index < characters.count, characters[index] == "/" { index += 1 }
                    continue
                }
                tokens.append(.star)
            case "?":
                tokens.append(.any)
            case "[":
                var end = index + 1
                var negated = false
                if end < characters.count, characters[end] == "!" || characters[end] == "^" {
                    negated = true
                    end += 1
                }
                var ranges: [ClosedRange<Character>] = []
                var cursor = end
                while cursor < characters.count, characters[cursor] != "]" || cursor == end {
                    let low = characters[cursor]
                    if cursor + 2 < characters.count, characters[cursor + 1] == "-", characters[cursor + 2] != "]" {
                        let high = characters[cursor + 2]
                        if low <= high { ranges.append(low...high) }
                        cursor += 3
                    } else {
                        ranges.append(low...low)
                        cursor += 1
                    }
                }
                if cursor < characters.count {
                    tokens.append(.set(ranges, negated: negated))
                    index = cursor
                } else {
                    tokens.append(.literal("["))
                }
            case "\\":
                if index + 1 < characters.count {
                    tokens.append(.literal(characters[index + 1]))
                    index += 1
                }
            default:
                tokens.append(.literal(character))
            }
            index += 1
        }
        return tokens
    }

    static func match(_ pattern: ArraySlice<Token>, _ text: ArraySlice<Character>) -> Bool {
        guard let token = pattern.first else { return text.isEmpty }
        let rest = pattern.dropFirst()
        switch token {
        case .literal(let character):
            guard let first = text.first, first == character else { return false }
            return match(rest, text.dropFirst())
        case .any:
            guard let first = text.first, first != "/" else { return false }
            return match(rest, text.dropFirst())
        case .set(let ranges, let negated):
            guard let first = text.first, first != "/" else { return false }
            let inSet = ranges.contains { $0.contains(first) }
            guard inSet != negated else { return false }
            return match(rest, text.dropFirst())
        case .star:
            var remaining = text
            while true {
                if match(rest, remaining) { return true }
                guard let first = remaining.first, first != "/" else { return false }
                remaining = remaining.dropFirst()
            }
        case .globstar:
            var remaining = text
            while true {
                if match(rest, remaining) { return true }
                guard !remaining.isEmpty else { return false }
                remaining = remaining.dropFirst()
            }
        }
    }
}
