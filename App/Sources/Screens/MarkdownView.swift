import AgentCore
import ChatMarkdown
import SwiftUI
import UIKit

/// Parsed replies, kept so finished messages aren't parsed again on every redraw.
/// Keyed by SHA-256 + length digest so dictionary keys never duplicate full 80 KB message bodies.
@MainActor
final class MarkdownCache {
    static let shared = MarkdownCache()
    private var documents: [String: MarkdownDocument] = [:]
    private var order: [String] = []
    private var highlightedCode: [String: AttributedString] = [:]
    private var codeOrder: [String] = []

    private static func digestKey(for text: String) -> String {
        "\(text.utf8.count):\(Hashing.sha256Hex(Data(text.utf8)))"
    }

    func document(for text: String, cacheable: Bool = true) -> MarkdownDocument {
        let key = Self.digestKey(for: text)
        if let cached = documents[key] { return cached }
        let document = MarkdownDocument(parsing: text)
        guard cacheable else { return document }
        documents[key] = document
        order.append(key)
        if order.count > 240 {
            documents[order.removeFirst()] = nil
        }
        return document
    }

    func highlighted(code: String, language: String?, dark: Bool, cacheable: Bool = true) -> AttributedString {
        let key = "\(dark ? 1 : 0):\(language ?? ""):\(Self.digestKey(for: code))"
        if let cached = highlightedCode[key] { return cached }
        let palette = CodePalette(dark: dark)
        var result = AttributedString()
        for token in SyntaxHighlighter.highlight(code, language: language) {
            var piece = AttributedString(token.text)
            piece.foregroundColor = palette.color(token.kind)
            if token.kind == .added { piece.backgroundColor = palette.addedBackground }
            if token.kind == .removed { piece.backgroundColor = palette.removedBackground }
            result += piece
        }
        guard cacheable else { return result }
        highlightedCode[key] = result
        codeOrder.append(key)
        if codeOrder.count > 180 {
            highlightedCode[codeOrder.removeFirst()] = nil
        }
        return result
    }
}

/// An AI reply drawn natively: headings, paragraphs, lists, quotes, tables and coloured code.
struct MarkdownView: View {
    var text: String
    var isStreaming: Bool = false

    var body: some View {
        let document = MarkdownCache.shared.document(for: text, cacheable: !isStreaming)
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(document.blocks.enumerated()), id: \.offset) { index, block in
                let blockIsLive = isStreaming && index == document.blocks.count - 1
                MarkdownBlockView(block: block, isStreaming: blockIsLive)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct MarkdownBlockView: View {
    var block: MarkdownBlock
    var isStreaming: Bool = false
    @Environment(\.theme) private var theme

    var body: some View {
        switch block {
        case .paragraph(let text):
            Text(InlineStyler.attributed(text, accent: theme.accent))
                .font(.body)
                .lineSpacing(3)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        case .heading(let level, let text):
            Text(InlineStyler.attributed(text, accent: theme.accent))
                .font(headingFont(level))
                .padding(.top, level <= 2 ? 6 : 2)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        case .code(let language, let code):
            let normalizedLang = language?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if normalizedLang == "mermaid" || normalizedLang == "mmd" {
                MermaidBlockView(code: code, isStreaming: isStreaming)
            } else {
                CodeBlockView(language: language, code: code, isStreaming: isStreaming)
            }
        case .quote(let blocks):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 2).fill(theme.accent.opacity(0.7)).frame(width: 3)
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(blocks.enumerated()), id: \.offset) { _, child in
                        MarkdownBlockView(block: child)
                    }
                }
                .foregroundStyle(Theme.secondaryText)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .list(let list):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(list.items.enumerated()), id: \.offset) { offset, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        marker(list: list, offset: offset, item: item)
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(item.blocks.enumerated()), id: \.offset) { _, child in
                                MarkdownBlockView(block: child)
                            }
                        }
                    }
                }
            }
        case .table(let table):
            TableView(table: table)
        case .divider:
            Rectangle().fill(Theme.stroke).frame(height: 1).padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private func marker(list: MarkdownList, offset: Int, item: MarkdownListItem) -> some View {
        if let checkbox = item.checkbox {
            Image(systemName: checkbox == .checked ? "checkmark.square.fill" : "square")
                .foregroundStyle(checkbox == .checked ? theme.accent : Theme.secondaryText)
        } else if list.isOrdered {
            Text("\(list.start + offset).")
                .font(.body.monospacedDigit())
                .foregroundStyle(Theme.secondaryText)
        } else {
            Text("•").foregroundStyle(theme.accent)
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .rounded(.title2, weight: .bold)
        case 2: return .rounded(.title3, weight: .bold)
        case 3: return .rounded(.headline, weight: .bold)
        default: return .headline
        }
    }
}

enum InlineStyler {
    /// One paragraph's runs as styled text: bold, italics, struck-out, code, and tappable links.
    static func attributed(_ text: InlineText, accent: Color) -> AttributedString {
        var result = AttributedString()
        for run in text.runs {
            var piece = AttributedString(run.text)
            var font: Font = .body
            if run.style.contains(.code) {
                font = .system(.callout, design: .monospaced)
                if run.style.contains(.bold) { font = font.bold() }
                piece.backgroundColor = Theme.codeBackground
            } else {
                if run.style.contains(.bold) { font = font.bold() }
                if run.style.contains(.italic) { font = font.italic() }
            }
            piece.font = font
            if run.style.contains(.strikethrough) { piece.strikethroughStyle = Text.LineStyle.single }
            if let link = run.link {
                piece.link = link
                piece.foregroundColor = accent
            }
            result += piece
        }
        return result
    }
}

/// A code block with its language, a copy button, and colours.
struct CodeBlockView: View {
    var language: String?
    var code: String
    var isStreaming: Bool = false
    @State private var copied = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language?.lowercased() ?? "code")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Theme.secondaryText)
                Spacer()
                Button {
                    UIPasteboard.general.string = code
                    copied = true
                    Task {
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        copied = false
                    }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption.weight(.medium))
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.secondaryText)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Rectangle().fill(Theme.stroke).frame(height: 1)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(highlighted)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(12)
            }
        }
        .background(Theme.codeBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.stroke))
    }

    private var highlighted: AttributedString {
        MarkdownCache.shared.highlighted(code: code, language: language, dark: colorScheme == .dark, cacheable: !isStreaming)
    }
}

/// Code colours that read well on both backgrounds.
struct CodePalette {
    var dark: Bool

    func color(_ kind: SyntaxHighlighter.Kind) -> Color {
        switch kind {
        case .plain: return dark ? Color(white: 0.9) : Color(white: 0.12)
        case .keyword: return dark ? Color(red: 1.0, green: 0.48, blue: 0.69) : Color(red: 0.69, green: 0.13, blue: 0.47)
        case .string: return dark ? Color(red: 0.99, green: 0.76, blue: 0.43) : Color(red: 0.72, green: 0.38, blue: 0.0)
        case .comment: return dark ? Color(white: 0.52) : Color(white: 0.47)
        case .number: return dark ? Color(red: 0.62, green: 0.71, blue: 1.0) : Color(red: 0.2, green: 0.31, blue: 0.82)
        case .type: return dark ? Color(red: 0.36, green: 0.91, blue: 0.79) : Color(red: 0.0, green: 0.5, blue: 0.43)
        case .function: return dark ? Color(red: 0.55, green: 0.82, blue: 1.0) : Color(red: 0.09, green: 0.42, blue: 0.7)
        case .attribute: return dark ? Color(red: 0.86, green: 0.67, blue: 1.0) : Color(red: 0.47, green: 0.26, blue: 0.75)
        case .added: return dark ? Color(red: 0.55, green: 0.9, blue: 0.6) : Color(red: 0.1, green: 0.5, blue: 0.2)
        case .removed: return dark ? Color(red: 1.0, green: 0.55, blue: 0.55) : Color(red: 0.7, green: 0.15, blue: 0.15)
        case .meta: return dark ? Color(red: 0.55, green: 0.82, blue: 1.0) : Color(red: 0.09, green: 0.42, blue: 0.7)
        }
    }

    var addedBackground: Color { Color.green.opacity(dark ? 0.14 : 0.1) }
    var removedBackground: Color { Color.red.opacity(dark ? 0.14 : 0.1) }
}

/// A Markdown table, scrolling sideways when it's wider than the phone.
struct TableView: View {
    var table: MarkdownTable
    @Environment(\.theme) private var theme

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                GridRow {
                    ForEach(Array(table.header.enumerated()), id: \.offset) { index, cell in
                        Text(InlineStyler.attributed(cell, accent: theme.accent))
                            .font(.subheadline.weight(.semibold))
                            .gridColumnAlignment(alignment(index))
                    }
                }
                Divider().gridCellUnsizedAxes(.horizontal)
                ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            Text(InlineStyler.attributed(cell, accent: theme.accent))
                                .font(.subheadline)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            .padding(12)
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.stroke))
    }

    private func alignment(_ index: Int) -> HorizontalAlignment {
        guard index < table.alignments.count else { return .leading }
        switch table.alignments[index] {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }
}
