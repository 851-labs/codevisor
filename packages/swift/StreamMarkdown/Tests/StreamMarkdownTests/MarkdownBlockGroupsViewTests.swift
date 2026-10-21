import Testing

@testable import StreamMarkdown

@Suite("MarkdownBlockGroupsView")
@MainActor
struct MarkdownBlockGroupsViewTests {
  @Test("Consecutive text blocks share one group and other blocks stand alone")
  func groupsTextRuns() {
    let code = MarkdownBlock.codeBlock(language: "swift", code: "let x = 1", isComplete: true)
    let blocks: [MarkdownBlock] = [
      .paragraph("Coming up:"),
      .bulletList(["one", "two"]),
      code,
      .paragraph("After"),
      .paragraph("Still after"),
      .thematicBreak,
    ]
    #expect(
      MarkdownBlockGroupsView.groups(blocks) == [
        [.paragraph("Coming up:"), .bulletList(["one", "two"])],
        [code],
        [.paragraph("After"), .paragraph("Still after")],
        [.thematicBreak],
      ])
  }
}
