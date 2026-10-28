import Foundation

/// Colours code in replies, for the languages people use most. A fast, forgiving scanner rather
/// than a full parser: it never fails, it handles half-written code (a reply that is still
/// streaming), and it runs on every update without slowing the chat.
public enum SyntaxHighlighter {
    public enum Kind: Sendable, Hashable {
        case plain, keyword, string, comment, number, type, function, attribute, added, removed, meta
    }

    public struct Token: Sendable, Hashable {
        public var text: String
        public var kind: Kind
        public init(text: String, kind: Kind) {
            self.text = text
            self.kind = kind
        }
    }

    public static func highlight(_ code: String, language: String?) -> [Token] {
        guard let spec = Spec.for(language) else { return code.isEmpty ? [] : [Token(text: code, kind: .plain)] }
        if spec.isDiff { return diff(code) }
        var scanner = Scanner(code: code, spec: spec)
        return scanner.run()
    }

    // MARK: Languages

    struct Spec {
        var lineComments: [String] = []
        var blockComments: [(open: String, close: String)] = []
        var quotes: [Character] = ["\"", "'"]
        var tripleQuotes = false
        var keywords: Set<String> = []
        var literals: Set<String> = []
        var caseInsensitive = false
        var capitalizedAreTypes = true
        var markup = false
        var isDiff = false
        /// `@Attribute` in Swift, decorators in Python and Java, `#[derive]`-like in Rust.
        var attributePrefix: Character?
        /// `$name` variables in shell and PHP.
        var dollarVariables = false

        static func `for`(_ language: String?) -> Spec? {
            let name = (language ?? "").lowercased().split(separator: " ").first.map(String.init) ?? ""
            switch name {
            case "swift":
                return Spec(lineComments: ["//"], blockComments: [("/*", "*/")], quotes: ["\""], tripleQuotes: true, keywords: swiftKeywords, literals: commonLiterals.union(["nil"]), attributePrefix: "@")
            case "js", "javascript", "jsx", "mjs", "cjs", "ts", "typescript", "tsx":
                return Spec(lineComments: ["//"], blockComments: [("/*", "*/")], quotes: ["\"", "'", "`"], keywords: jsKeywords, literals: commonLiterals.union(["null", "undefined", "NaN", "Infinity"]), attributePrefix: "@")
            case "java", "kotlin", "kt", "kts", "scala", "groovy", "gradle", "dart", "cs", "csharp", "c#":
                return Spec(lineComments: ["//"], blockComments: [("/*", "*/")], quotes: ["\"", "'"], tripleQuotes: name == "kotlin" || name == "kt" || name == "scala" || name == "dart", keywords: jvmKeywords, literals: commonLiterals.union(["null"]), attributePrefix: "@")
            case "c", "h", "cpp", "c++", "cc", "cxx", "hpp", "objc", "objective-c", "m", "mm", "metal", "glsl", "hlsl", "cuda":
                return Spec(lineComments: ["//"], blockComments: [("/*", "*/")], quotes: ["\"", "'"], keywords: cKeywords, literals: commonLiterals.union(["NULL", "nullptr", "nil", "YES", "NO"]), attributePrefix: "#")
            case "go", "golang":
                return Spec(lineComments: ["//"], blockComments: [("/*", "*/")], quotes: ["\"", "'", "`"], keywords: goKeywords, literals: commonLiterals.union(["nil", "iota"]))
            case "rust", "rs":
                return Spec(lineComments: ["//"], blockComments: [("/*", "*/")], quotes: ["\""], keywords: rustKeywords, literals: commonLiterals.union(["None", "Some", "Ok", "Err"]), attributePrefix: "#")
            case "php":
                return Spec(lineComments: ["//", "#"], blockComments: [("/*", "*/")], keywords: phpKeywords, literals: commonLiterals.union(["null"]), caseInsensitive: true, dollarVariables: true)
            case "python", "py", "python3", "gyp":
                return Spec(lineComments: ["#"], quotes: ["\"", "'"], tripleQuotes: true, keywords: pythonKeywords, literals: ["True", "False", "None"], attributePrefix: "@")
            case "ruby", "rb":
                return Spec(lineComments: ["#"], quotes: ["\"", "'"], keywords: rubyKeywords, literals: commonLiterals.union(["nil"]))
            case "sh", "bash", "zsh", "shell", "console", "shellsession", "fish", "ps1", "powershell", "dockerfile", "docker", "make", "makefile", "cmake":
                return Spec(lineComments: ["#"], quotes: ["\"", "'"], keywords: shellKeywords, literals: commonLiterals, capitalizedAreTypes: false, dollarVariables: true)
            case "yaml", "yml", "toml", "ini", "conf", "properties", "env", "dotenv":
                return Spec(lineComments: ["#", ";"], quotes: ["\"", "'"], literals: commonLiterals.union(["null", "yes", "no", "on", "off", "~"]), capitalizedAreTypes: false)
            case "json", "jsonc", "json5", "geojson":
                return Spec(lineComments: name == "json" ? [] : ["//"], blockComments: name == "json" ? [] : [("/*", "*/")], quotes: ["\""], literals: ["true", "false", "null"], capitalizedAreTypes: false)
            case "sql", "mysql", "postgres", "postgresql", "sqlite", "plsql":
                return Spec(lineComments: ["--"], blockComments: [("/*", "*/")], quotes: ["'", "\""], keywords: sqlKeywords, literals: ["true", "false", "null"], caseInsensitive: true, capitalizedAreTypes: false)
            case "lua":
                return Spec(lineComments: ["--"], blockComments: [("--[[", "]]")], quotes: ["\"", "'"], keywords: luaKeywords, literals: commonLiterals.union(["nil"]))
            case "html", "htm", "xml", "svg", "plist", "xhtml", "vue", "svelte", "xaml", "storyboard":
                return Spec(blockComments: [("<!--", "-->")], quotes: ["\"", "'"], capitalizedAreTypes: false, markup: true)
            case "css", "scss", "sass", "less":
                return Spec(lineComments: name == "css" ? [] : ["//"], blockComments: [("/*", "*/")], quotes: ["\"", "'"], keywords: ["important", "media", "import", "keyframes", "font-face", "supports", "include", "mixin", "extend", "use"], capitalizedAreTypes: false, attributePrefix: "@")
            case "diff", "patch", "udiff":
                return Spec(isDiff: true)
            default:
                return nil
            }
        }
    }

    static let commonLiterals: Set<String> = ["true", "false"]
    static let swiftKeywords: Set<String> = [
        "actor", "any", "as", "associatedtype", "async", "await", "break", "case", "catch", "class", "continue", "convenience",
        "default", "defer", "deinit", "didSet", "do", "dynamic", "else", "enum", "extension", "fallthrough", "fileprivate",
        "final", "for", "func", "get", "guard", "if", "import", "in", "indirect", "init", "inout", "internal", "is", "isolated",
        "lazy", "let", "macro", "mutating", "nonisolated", "nonmutating", "open", "operator", "optional", "override", "package",
        "precedencegroup", "private", "protocol", "public", "repeat", "required", "rethrows", "return", "self", "Self",
        "set", "some", "static", "struct", "subscript", "super", "switch", "throw", "throws", "try", "typealias", "unowned",
        "var", "weak", "where", "while", "willSet", "consuming", "borrowing", "sending",
    ]
    static let jsKeywords: Set<String> = [
        "abstract", "as", "async", "await", "break", "case", "catch", "class", "const", "constructor", "continue", "debugger",
        "declare", "default", "delete", "do", "else", "enum", "export", "extends", "finally", "for", "from", "function", "get",
        "if", "implements", "import", "in", "instanceof", "interface", "is", "keyof", "let", "module", "namespace", "new", "of",
        "private", "protected", "public", "readonly", "return", "satisfies", "set", "static", "super", "switch", "this",
        "throw", "try", "type", "typeof", "var", "void", "while", "with", "yield",
    ]
    static let jvmKeywords: Set<String> = [
        "abstract", "as", "assert", "async", "await", "break", "case", "catch", "class", "companion", "const", "continue",
        "data", "def", "default", "do", "else", "enum", "extends", "external", "final", "finally", "for", "fun", "get", "if",
        "implements", "import", "in", "init", "inline", "inner", "instanceof", "interface", "internal", "is", "it", "lateinit",
        "late", "native", "new", "object", "open", "operator", "override", "package", "private", "protected", "public",
        "required", "return", "sealed", "set", "static", "super", "suspend", "switch", "synchronized", "this", "throw",
        "throws", "transient", "try", "typealias", "val", "var", "void", "volatile", "when", "where", "while", "with", "yield",
        "namespace", "using", "struct", "readonly", "ref", "out", "params", "base", "lock", "event", "delegate", "implicit",
        "explicit", "unsafe", "fixed", "sizeof", "typeof", "trait", "match", "case", "lazy", "implicit",
    ]
    static let cKeywords: Set<String> = [
        "auto", "break", "case", "char", "class", "const", "constexpr", "continue", "default", "delete", "do", "double",
        "else", "enum", "explicit", "extern", "float", "for", "friend", "goto", "if", "include", "define", "ifdef", "ifndef",
        "endif", "pragma", "inline", "int", "long", "mutable", "namespace", "new", "noexcept", "operator", "private",
        "protected", "public", "register", "return", "short", "signed", "sizeof", "static", "struct", "switch", "template",
        "this", "throw", "try", "typedef", "typename", "union", "unsigned", "using", "virtual", "void", "volatile", "while",
        "bool", "uint8_t", "uint16_t", "uint32_t", "uint64_t", "int8_t", "int16_t", "int32_t", "int64_t", "size_t",
        "interface", "implementation", "end", "property", "nonatomic", "strong", "weak", "self", "super", "kernel",
        "device", "constant", "thread", "threadgroup", "vertex", "fragment", "uniform", "in", "out",
    ]
    static let goKeywords: Set<String> = [
        "break", "case", "chan", "const", "continue", "default", "defer", "else", "fallthrough", "for", "func", "go", "goto",
        "if", "import", "interface", "map", "package", "range", "return", "select", "struct", "switch", "type", "var",
        "string", "int", "int64", "int32", "uint", "byte", "rune", "float64", "bool", "error", "any",
    ]
    static let rustKeywords: Set<String> = [
        "as", "async", "await", "break", "const", "continue", "crate", "dyn", "else", "enum", "extern", "fn", "for", "if",
        "impl", "in", "let", "loop", "match", "mod", "move", "mut", "pub", "ref", "return", "self", "Self", "static",
        "struct", "super", "trait", "type", "unsafe", "use", "where", "while", "u8", "u16", "u32", "u64", "u128", "usize",
        "i8", "i16", "i32", "i64", "i128", "isize", "f32", "f64", "bool", "char", "str",
    ]
    static let phpKeywords: Set<String> = [
        "abstract", "and", "array", "as", "break", "case", "catch", "class", "const", "continue", "declare", "default", "do",
        "echo", "else", "elseif", "extends", "final", "finally", "fn", "for", "foreach", "function", "global", "if",
        "implements", "include", "instanceof", "interface", "match", "namespace", "new", "or", "private", "protected",
        "public", "require", "return", "static", "switch", "throw", "trait", "try", "use", "var", "while", "yield",
    ]
    static let pythonKeywords: Set<String> = [
        "and", "as", "assert", "async", "await", "break", "case", "class", "continue", "def", "del", "elif", "else", "except",
        "finally", "for", "from", "global", "if", "import", "in", "is", "lambda", "match", "nonlocal", "not", "or", "pass",
        "raise", "return", "self", "try", "while", "with", "yield",
    ]
    static let rubyKeywords: Set<String> = [
        "alias", "and", "begin", "break", "case", "class", "def", "defined?", "do", "else", "elsif", "end", "ensure", "for",
        "if", "in", "module", "next", "not", "or", "redo", "require", "rescue", "retry", "return", "self", "super", "then",
        "undef", "unless", "until", "when", "while", "yield", "attr_reader", "attr_accessor", "private", "public",
    ]
    static let shellKeywords: Set<String> = [
        "if", "then", "else", "elif", "fi", "case", "esac", "for", "while", "until", "do", "done", "in", "function", "return",
        "exit", "export", "local", "readonly", "set", "unset", "source", "echo", "cd", "sudo", "trap", "shift", "eval",
        "FROM", "RUN", "CMD", "COPY", "ADD", "WORKDIR", "ENV", "ARG", "EXPOSE", "ENTRYPOINT", "USER", "VOLUME", "LABEL",
    ]
    static let sqlKeywords: Set<String> = [
        "select", "from", "where", "and", "or", "not", "insert", "into", "values", "update", "set", "delete", "create",
        "table", "drop", "alter", "add", "index", "primary", "key", "foreign", "references", "join", "left", "right",
        "inner", "outer", "on", "as", "group", "by", "order", "having", "limit", "offset", "distinct", "union", "all",
        "case", "when", "then", "else", "end", "is", "in", "like", "between", "exists", "default", "unique", "view",
        "begin", "commit", "rollback", "transaction", "with", "returning", "integer", "text", "varchar", "boolean",
    ]
    static let luaKeywords: Set<String> = [
        "and", "break", "do", "else", "elseif", "end", "for", "function", "goto", "if", "in", "local", "not", "or",
        "repeat", "return", "then", "until", "while",
    ]

    // MARK: Diff

    static func diff(_ code: String) -> [Token] {
        var tokens: [Token] = []
        let lines = code.split(separator: "\n", omittingEmptySubsequences: false)
        for (index, line) in lines.enumerated() {
            let text = String(line) + (index < lines.count - 1 ? "\n" : "")
            let kind: Kind
            if line.hasPrefix("+++") || line.hasPrefix("---") || line.hasPrefix("diff ") || line.hasPrefix("index ") {
                kind = .meta
            } else if line.hasPrefix("@@") {
                kind = .meta
            } else if line.hasPrefix("+") {
                kind = .added
            } else if line.hasPrefix("-") {
                kind = .removed
            } else {
                kind = .plain
            }
            append(&tokens, text, kind)
        }
        return tokens
    }

    static func append(_ tokens: inout [Token], _ text: String, _ kind: Kind) {
        guard !text.isEmpty else { return }
        if let last = tokens.last, last.kind == kind {
            tokens[tokens.count - 1].text += text
        } else {
            tokens.append(Token(text: text, kind: kind))
        }
    }

    // MARK: Scanner

    struct Scanner {
        let chars: [Character]
        let spec: Spec
        var index = 0
        var tokens: [Token] = []
        var plain = ""

        init(code: String, spec: Spec) {
            chars = Array(code)
            self.spec = spec
        }

        mutating func flushPlain() {
            if !plain.isEmpty {
                SyntaxHighlighter.append(&tokens, plain, .plain)
                plain = ""
            }
        }

        mutating func emit(_ text: String, _ kind: Kind) {
            flushPlain()
            SyntaxHighlighter.append(&tokens, text, kind)
        }

        func starts(with marker: String, at position: Int) -> Bool {
            let markerChars = Array(marker)
            guard position + markerChars.count <= chars.count else { return false }
            for offset in 0..<markerChars.count where chars[position + offset] != markerChars[offset] { return false }
            return true
        }

        func text(_ range: Range<Int>) -> String {
            String(chars[range])
        }

        mutating func run() -> [Token] {
            while index < chars.count {
                if spec.markup, scanMarkup() { continue }
                if scanComment() { continue }
                if scanString() { continue }
                let character = chars[index]
                if character.isNumber, index == 0 || !Self.isIdentifierPart(chars[index - 1]) {
                    scanNumber()
                    continue
                }
                if let prefix = spec.attributePrefix, character == prefix, index + 1 < chars.count, Self.isIdentifierStart(chars[index + 1]) {
                    let start = index
                    index += 1
                    while index < chars.count, Self.isIdentifierPart(chars[index]) || chars[index] == "-" { index += 1 }
                    emit(text(start..<index), .attribute)
                    continue
                }
                if spec.dollarVariables, character == "$", index + 1 < chars.count, Self.isIdentifierStart(chars[index + 1]) || chars[index + 1] == "{" {
                    let start = index
                    index += 1
                    if chars[index] == "{" {
                        while index < chars.count, chars[index] != "}", chars[index] != "\n" { index += 1 }
                        if index < chars.count, chars[index] == "}" { index += 1 }
                    } else {
                        while index < chars.count, Self.isIdentifierPart(chars[index]) { index += 1 }
                    }
                    emit(text(start..<index), .attribute)
                    continue
                }
                if Self.isIdentifierStart(character) {
                    scanWord()
                    continue
                }
                plain.append(character)
                index += 1
            }
            flushPlain()
            return tokens
        }

        mutating func scanComment() -> Bool {
            for marker in spec.lineComments where starts(with: marker, at: index) {
                // "#" starts a comment only at a word boundary, so "a#b" and "#!" stay sensible.
                if marker == "#", index > 0, !chars[index - 1].isWhitespace, chars[index - 1] != ";" { continue }
                let start = index
                while index < chars.count, chars[index] != "\n" { index += 1 }
                emit(text(start..<index), .comment)
                return true
            }
            for pair in spec.blockComments where starts(with: pair.open, at: index) {
                let start = index
                index += pair.open.count
                while index < chars.count, !starts(with: pair.close, at: index) { index += 1 }
                index = min(chars.count, index + pair.close.count)
                emit(text(start..<index), .comment)
                return true
            }
            return false
        }

        mutating func scanString() -> Bool {
            let character = chars[index]
            guard spec.quotes.contains(character) else { return false }
            // An apostrophe straight after a letter ("don't" in a shell echo) doesn't open a string.
            if character == "'", index > 0, Self.isIdentifierPart(chars[index - 1]) { return false }
            let start = index
            let triple = spec.tripleQuotes && starts(with: String(repeating: String(character), count: 3), at: index)
            if triple {
                index += 3
                let close = String(repeating: String(character), count: 3)
                while index < chars.count, !starts(with: close, at: index) {
                    index += chars[index] == "\\" ? 2 : 1
                }
                index = min(chars.count, index + 3)
            } else {
                index += 1
                while index < chars.count, chars[index] != character {
                    if chars[index] == "\\" { index += 1 }
                    // A plain string ends at the line's end (except template strings), so an
                    // unclosed quote can't colour the rest of the reply.
                    else if chars[index] == "\n", character != "`" { break }
                    index += 1
                }
                if index < chars.count, chars[index] == character { index += 1 }
                index = min(index, chars.count)
            }
            emit(text(start..<index), .string)
            return true
        }

        mutating func scanNumber() {
            let start = index
            if starts(with: "0x", at: index) || starts(with: "0X", at: index) || starts(with: "0b", at: index) || starts(with: "0o", at: index) {
                index += 2
            }
            while index < chars.count, chars[index].isHexDigit || chars[index] == "_" || chars[index] == "." && index + 1 < chars.count && chars[index + 1].isNumber {
                index += 1
            }
            // Exponents and type suffixes: 1e10, 2.5f, 10u64.
            while index < chars.count, chars[index].isLetter || chars[index].isNumber { index += 1 }
            emit(text(start..<index), .number)
        }

        mutating func scanWord() {
            let start = index
            while index < chars.count, Self.isIdentifierPart(chars[index]) { index += 1 }
            if index < chars.count, chars[index] == "?" || chars[index] == "!", spec.keywords.contains(text(start..<(index + 1))) { index += 1 }
            let word = text(start..<index)
            let lookup = spec.caseInsensitive ? word.lowercased() : word
            var next = index
            while next < chars.count, chars[next] == " " { next += 1 }
            if spec.keywords.contains(lookup) || spec.keywords.contains(word) {
                emit(word, .keyword)
            } else if spec.literals.contains(lookup) || spec.literals.contains(word) {
                emit(word, .number)
            } else if next < chars.count, chars[next] == "(" {
                emit(word, .function)
            } else if spec.capitalizedAreTypes, let first = word.first, first.isUppercase {
                // ALL_CAPS names are constants, not types.
                if word.allSatisfy({ $0.isUppercase || $0 == "_" || $0.isNumber }), word.count > 1 {
                    emit(word, .number)
                } else {
                    emit(word, .type)
                }
            } else {
                plain += word
            }
        }

        /// Tags, attribute names and values in HTML and XML.
        mutating func scanMarkup() -> Bool {
            if starts(with: "<!--", at: index) { return false }
            guard chars[index] == "<", index + 1 < chars.count, chars[index + 1].isLetter || chars[index + 1] == "/" || chars[index + 1] == "!" || chars[index + 1] == "?" else { return false }
            var position = index + 1
            if chars[position] == "/" || chars[position] == "!" || chars[position] == "?" { position += 1 }
            while position < chars.count, Self.isIdentifierPart(chars[position]) || chars[position] == "-" || chars[position] == ":" || chars[position] == "." { position += 1 }
            emit(text(index..<position), .keyword)
            index = position
            while index < chars.count, chars[index] != ">" {
                let character = chars[index]
                if character == "\"" || character == "'" {
                    let start = index
                    index += 1
                    while index < chars.count, chars[index] != character { index += 1 }
                    index = min(chars.count, index + 1)
                    emit(text(start..<index), .string)
                } else if Self.isIdentifierStart(character) {
                    let start = index
                    while index < chars.count, Self.isIdentifierPart(chars[index]) || chars[index] == "-" || chars[index] == ":" { index += 1 }
                    emit(text(start..<index), .attribute)
                } else {
                    plain.append(character)
                    index += 1
                }
            }
            if index < chars.count {
                var close = ">"
                if let last = plain.last, last == "/" || last == "?" {
                    plain.removeLast()
                    close = String(last) + ">"
                }
                emit(close, .keyword)
                index += 1
            }
            return true
        }

        static func isIdentifierStart(_ character: Character) -> Bool {
            character.isLetter || character == "_"
        }

        static func isIdentifierPart(_ character: Character) -> Bool {
            character.isLetter || character.isNumber || character == "_"
        }
    }
}
