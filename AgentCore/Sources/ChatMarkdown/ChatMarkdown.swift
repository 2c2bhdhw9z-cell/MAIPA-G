import Foundation
import Markdown

/// An AI reply, parsed from Markdown (GitHub's flavour) into blocks the app can draw natively.
///
/// Parsing uses Apple's swift-markdown (cmark-gfm), so tables, task lists, strikethrough and
/// fenced code behave exactly as on GitHub. The one deliberate difference: a single line break
/// inside a paragraph stays a line break. AI replies use them for lists of steps, addresses and
/// verse, and joining those lines into one would scramble them.
public struct MarkdownDocument: Sendable, Equatable {
    public var blocks: [MarkdownBlock]

    public init(blocks: [MarkdownBlock]) {
        self.blocks = blocks
    }

    public init(parsing text: String) {
        let document = Document(parsing: text, options: [.disableSmartOpts])
        blocks = document.children.compactMap(MarkdownConverter.block)
    }

    /// All the plain text, for copying and for searching chats.
    public var plainText: String {
        blocks.map(\.plainText).joined(separator: "\n\n")
    }
}

public enum MarkdownBlock: Sendable, Equatable {
    case paragraph(InlineText)
    case heading(level: Int, InlineText)
    case code(language: String?, text: String)
    case quote([MarkdownBlock])
    case list(MarkdownList)
    case table(MarkdownTable)
    case divider

    public var plainText: String {
        switch self {
        case .paragraph(let text), .heading(_, let text): return text.plainText
        case .code(_, let text): return text
        case .quote(let blocks): return blocks.map(\.plainText).joined(separator: "\n")
        case .list(let list):
            return list.items.enumerated().map { offset, item in
                let marker = list.isOrdered ? "\(list.start + offset)." : "•"
                return "\(marker) " + item.blocks.map(\.plainText).joined(separator: "\n")
            }.joined(separator: "\n")
        case .table(let table):
            return ([table.header] + table.rows).map { $0.map(\.plainText).joined(separator: "\t") }.joined(separator: "\n")
        case .divider: return "---"
        }
    }
}

public struct MarkdownList: Sendable, Equatable {
    public var isOrdered: Bool
    public var start: Int
    public var items: [MarkdownListItem]
}

public struct MarkdownListItem: Sendable, Equatable {
    public enum Checkbox: Sendable, Equatable { case checked, unchecked }
    public var checkbox: Checkbox?
    public var blocks: [MarkdownBlock]
}

public struct MarkdownTable: Sendable, Equatable {
    public enum Alignment: Sendable, Equatable { case leading, center, trailing }
    public var header: [InlineText]
    public var alignments: [Alignment]
    public var rows: [[InlineText]]
}

/// A run of formatted text inside one block.
public struct InlineText: Sendable, Equatable {
    public var runs: [InlineRun]

    public init(runs: [InlineRun]) {
        self.runs = runs
    }

    public var plainText: String { runs.map(\.text).joined() }
    public var isEmpty: Bool { runs.allSatisfy { $0.text.isEmpty } }
}

public struct InlineRun: Sendable, Equatable {
    public struct Style: OptionSet, Sendable, Hashable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let bold = Style(rawValue: 1 << 0)
        public static let italic = Style(rawValue: 1 << 1)
        public static let strikethrough = Style(rawValue: 1 << 2)
        public static let code = Style(rawValue: 1 << 3)
    }

    public var text: String
    public var style: Style
    public var link: URL?

    public init(text: String, style: Style = [], link: URL? = nil) {
        self.text = text
        self.style = style
        self.link = link
    }
}

enum MarkdownConverter {
    static func block(_ markup: Markup) -> MarkdownBlock? {
        switch markup {
        case let paragraph as Paragraph:
            let text = inline(paragraph)
            return text.isEmpty ? nil : .paragraph(text)
        case let heading as Heading:
            return .heading(level: min(max(heading.level, 1), 6), inline(heading))
        case let code as CodeBlock:
            var text = code.code
            if text.hasSuffix("\n") { text.removeLast() }
            let language = code.language?.trimmingCharacters(in: .whitespaces)
            return .code(language: (language?.isEmpty ?? true) ? nil : language, text: text)
        case let quote as BlockQuote:
            return .quote(quote.children.compactMap(block))
        case let list as UnorderedList:
            return .list(MarkdownList(isOrdered: false, start: 1, items: list.listItems.map(item)))
        case let list as OrderedList:
            return .list(MarkdownList(isOrdered: true, start: Int(list.startIndex), items: list.listItems.map(item)))
        case let table as Table:
            return .table(convert(table))
        case is ThematicBreak:
            return .divider
        case let html as HTMLBlock:
            return .code(language: "html", text: html.rawHTML.trimmingCharacters(in: .newlines))
        default:
            // Directives and anything newer than this converter: keep their text visible.
            let text = markup.format().trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : .paragraph(InlineText(runs: [InlineRun(text: text)]))
        }
    }

    static func item(_ item: ListItem) -> MarkdownListItem {
        let checkbox: MarkdownListItem.Checkbox?
        switch item.checkbox {
        case .checked: checkbox = .checked
        case .unchecked: checkbox = .unchecked
        case nil: checkbox = nil
        }
        return MarkdownListItem(checkbox: checkbox, blocks: item.children.compactMap(block))
    }

    static func convert(_ table: Table) -> MarkdownTable {
        let alignments: [MarkdownTable.Alignment] = table.columnAlignments.map { alignment in
            switch alignment {
            case .center: return .center
            case .right: return .trailing
            default: return .leading
            }
        }
        let header: [InlineText] = Array(table.head.cells.map { inline($0) })
        let rows: [[InlineText]] = Array(table.body.rows.map { row in Array(row.cells.map { inline($0) }) })
        let width = max(header.count, rows.map(\.count).max() ?? 0)
        func pad(_ cells: [InlineText]) -> [InlineText] {
            cells + Array(repeating: InlineText(runs: []), count: max(0, width - cells.count))
        }
        return MarkdownTable(
            header: pad(header),
            alignments: alignments + Array(repeating: .leading, count: max(0, width - alignments.count)),
            rows: rows.map(pad)
        )
    }

    static func inline(_ container: Markup) -> InlineText {
        var runs: [InlineRun] = []
        for child in container.children {
            collect(child, style: [], link: nil, into: &runs)
        }
        return InlineText(runs: merged(runs))
    }

    private static func collect(_ markup: Markup, style: InlineRun.Style, link: URL?, into runs: inout [InlineRun]) {
        switch markup {
        case let text as Text:
            runs.append(InlineRun(text: text.string, style: style, link: link))
        case let code as InlineCode:
            runs.append(InlineRun(text: code.code, style: style.union(.code), link: link))
        case is SoftBreak, is LineBreak:
            runs.append(InlineRun(text: "\n", style: style, link: link))
        case let emphasis as Emphasis:
            for child in emphasis.children { collect(child, style: style.union(.italic), link: link, into: &runs) }
        case let strong as Strong:
            for child in strong.children { collect(child, style: style.union(.bold), link: link, into: &runs) }
        case let strike as Strikethrough:
            for child in strike.children { collect(child, style: style.union(.strikethrough), link: link, into: &runs) }
        case let anchor as Link:
            let url = anchor.destination.flatMap(URL.init(string:))
            let before = runs.count
            for child in anchor.children { collect(child, style: style, link: url ?? link, into: &runs) }
            if runs.count == before, let destination = anchor.destination {
                runs.append(InlineRun(text: destination, style: style, link: url))
            }
        case let image as Image:
            let alt = image.plainText.isEmpty ? "picture" : image.plainText
            runs.append(InlineRun(text: alt, style: style.union(.italic), link: image.source.flatMap(URL.init(string:))))
        case let html as InlineHTML:
            runs.append(InlineRun(text: html.rawHTML, style: style.union(.code), link: link))
        default:
            if markup.childCount > 0 {
                for child in markup.children { collect(child, style: style, link: link, into: &runs) }
            } else if let text = (markup as? PlainTextConvertibleMarkup)?.plainText, !text.isEmpty {
                runs.append(InlineRun(text: text, style: style, link: link))
            }
        }
    }

    /// Joins neighbouring runs with the same look, so the app builds fewer text pieces.
    private static func merged(_ runs: [InlineRun]) -> [InlineRun] {
        var result: [InlineRun] = []
        for run in runs where !run.text.isEmpty {
            if let last = result.last, last.style == run.style, last.link == run.link {
                result[result.count - 1].text += run.text
            } else {
                result.append(run)
            }
        }
        return result
    }
}
