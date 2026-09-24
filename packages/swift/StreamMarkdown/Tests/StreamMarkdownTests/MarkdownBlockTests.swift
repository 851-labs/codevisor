import Foundation
import Testing
@testable import StreamMarkdown

@Suite("MarkdownBlock identity")
struct MarkdownBlockTests {
  @Test("Every block case produces a distinct identity")
  func ids() {
    let blocks: [MarkdownBlock] = [
      .heading(level: 2, text: "Title"),
      .paragraph("body"),
      .codeBlock(language: "swift", code: "x", isComplete: true),
      .bulletList(["a", "b"]),
      .orderedList([OrderedListItem(number: 1, text: "one")]),
      .blockQuote([.paragraph("quote")]),
      .table(headers: ["A", "B"], alignments: [.leading, .trailing], rows: [["1", "2"]]),
      .thematicBreak,
    ]
    let ids = blocks.map(\.id)
    #expect(Set(ids).count == ids.count)
    #expect(ids.contains("h2:Title"))
    #expect(ids.contains { $0.hasPrefix("code:swift") })
    #expect(ids.contains { $0.hasPrefix("ol:") })
    #expect(ids.contains { $0.hasPrefix("quote:") })
    #expect(ids.contains { $0.hasPrefix("table:A|B") })
  }
}
