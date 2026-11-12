import Foundation
import Testing
@testable import ChatMarkdown

@Suite("GitHub marks on links")
struct CodeHostLinkTests {
    @Test("GitHub and GitLab links are told apart from other links, written as links or bare")
    func recognisesCodeHostLinks() throws {
        #expect(CodeHostLink(URL(string: "https://github.com/o/r/actions/runs/1")!) == .github)
        #expect(CodeHostLink(URL(string: "https://gitlab.com/o/r/-/merge_requests/2")!) == .gitlab)
        #expect(CodeHostLink(URL(string: "https://example.com/github.com")!) == nil)
        #expect(CodeHostLink(URL(string: "http://github.com/o/r")!) == nil)
        let written = MarkdownDocument(parsing: "Published as [build 162](https://github.com/o/r/releases/tag/b).")
        let bare = MarkdownDocument(parsing: "The run: https://github.com/o/r/actions/runs/9 is green.")
        func links(_ document: MarkdownDocument) -> [URL] {
            document.blocks.flatMap { block -> [URL] in
                if case .paragraph(let text) = block { return text.runs.compactMap(\.link) }
                return []
            }
        }
        #expect(links(written).map(\.absoluteString) == ["https://github.com/o/r/releases/tag/b"])
        #expect(links(bare).map(\.absoluteString) == ["https://github.com/o/r/actions/runs/9"])
    }
}
