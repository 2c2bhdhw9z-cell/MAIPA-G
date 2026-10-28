import Foundation
import Testing
@testable import ChatMarkdown

@Suite("Markdown")
struct MarkdownTests {
    @Test func blocksAndInlineStyles() {
        let text = """
        # Title

        Some **bold**, *italic*, `code` and [a link](https://example.com).
        Second line stays separate.

        - one
        - [x] done
          1. nested

        > quoted

        ```swift
        let x = 1
        ```

        | Name | Size |
        |:-----|-----:|
        | a    | 1    |

        ---
        """
        let document = MarkdownDocument(parsing: text)
        guard document.blocks.count == 7 else {
            Issue.record("expected 7 blocks, got \(document.blocks.count): \(document.blocks)")
            return
        }
        #expect(document.blocks[0] == .heading(level: 1, InlineText(runs: [InlineRun(text: "Title")])))

        guard case .paragraph(let paragraph) = document.blocks[1] else { Issue.record("no paragraph"); return }
        #expect(paragraph.runs.contains(InlineRun(text: "bold", style: .bold)))
        #expect(paragraph.runs.contains(InlineRun(text: "italic", style: .italic)))
        #expect(paragraph.runs.contains(InlineRun(text: "code", style: .code)))
        #expect(paragraph.runs.contains(InlineRun(text: "a link", link: URL(string: "https://example.com"))))
        #expect(paragraph.plainText.contains(".\nSecond line"))

        guard case .list(let list) = document.blocks[2] else { Issue.record("no list"); return }
        #expect(!list.isOrdered && list.items.count == 2)
        #expect(list.items[1].checkbox == .checked)
        guard case .list(let nested)? = list.items[1].blocks.last else { Issue.record("no nested list"); return }
        #expect(nested.isOrdered && nested.start == 1)

        #expect(document.blocks[4] == .code(language: "swift", text: "let x = 1"))
        guard case .table(let table) = document.blocks[5] else { Issue.record("no table"); return }
        #expect(table.alignments == [.leading, .trailing])
        #expect(table.rows.first?.map(\.plainText) == ["a", "1"])
        #expect(document.blocks[6] == .divider)
    }

    @Test func unfinishedReplyStillParses() {
        // A reply cut mid-stream: an open code fence and a half-written table.
        let document = MarkdownDocument(parsing: "Here:\n\n```python\nprint('hi')\n| a | b |\n|---")
        #expect(document.blocks.count == 2)
        if case .code(let language, let text) = document.blocks[1] {
            #expect(language == "python")
            #expect(text.hasPrefix("print('hi')"))
        } else {
            Issue.record("expected a code block")
        }
    }
}

@Suite("Code colours")
struct SyntaxHighlighterTests {
    func kinds(_ code: String, _ language: String) -> [(String, SyntaxHighlighter.Kind)] {
        SyntaxHighlighter.highlight(code, language: language).map { ($0.text, $0.kind) }.filter { $0.1 != .plain }
    }

    @Test func swift() {
        let tokens = kinds("@MainActor func go() { let s = \"hi\" // note\n return 0x1F }", "swift")
        #expect(tokens.map(\.0) == ["@MainActor", "func", "go", "let", "\"hi\"", "// note", "return", "0x1F"])
        #expect(tokens.map(\.1) == [.attribute, .keyword, .function, .keyword, .string, .comment, .keyword, .number])
    }

    @Test func pythonTripleQuotesAndDecorators() {
        let tokens = kinds("@cache\ndef f():\n    \"\"\"Doc\nstring\"\"\"\n    return None  # done", "python")
        #expect(tokens.map(\.1) == [.attribute, .keyword, .function, .string, .keyword, .number, .comment])
    }

    @Test func textAlwaysSurvives() {
        let samples: [(String, String)] = [
            ("const a = `x ${y}` + 'z'; /* unclosed", "ts"),
            ("echo \"$HOME\" it's # comment", "bash"),
            ("<div class=\"a\">Hi <b>there</b></div><!-- c -->", "html"),
            ("{\"a\": [1, true, null]}", "json"),
            ("SELECT * FROM t WHERE name = 'x' -- why", "sql"),
            ("fn main() -> Result<(), String> { Ok(()) }", "rust"),
            ("\"unterminated string\nnext line", "swift"),
            ("", "swift"),
            ("plain words", "unknown-language"),
        ]
        for (code, language) in samples {
            let joined = SyntaxHighlighter.highlight(code, language: language).map(\.text).joined()
            #expect(joined == code, "\(language) changed the text")
        }
    }

    @Test func unterminatedStringStopsAtLineEnd() {
        let tokens = SyntaxHighlighter.highlight("\"open\nlet x = 1", language: "swift")
        #expect(tokens.first?.kind == .string && tokens.first?.text == "\"open")
        #expect(tokens.contains { $0.text == "let" && $0.kind == .keyword })
    }

    @Test func diffLines() {
        let tokens = SyntaxHighlighter.highlight("@@ -1 +1 @@\n-old\n+new\n same", language: "diff")
        #expect(tokens.map(\.kind) == [.meta, .removed, .added, .plain])
    }

    @Test func markupTagsAndAttributes() {
        let tokens = kinds("<a href=\"x\">", "html")
        #expect(tokens.map(\.0) == ["<a", "href", "\"x\"", ">"])
        #expect(tokens.map(\.1) == [.keyword, .attribute, .string, .keyword])
    }
}
