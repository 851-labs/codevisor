#if canImport(AppKit)
  import AppKit
  import StreamMarkdown
  import SwiftUI
  import Testing
  import TranscriptKit
  @testable import CodevisorUI

  @Suite("Bot message width")
  @MainActor
  struct TranscriptBotMessageWidthTests {
    private let table = """
      | 11/16 | Logged | Target |
      |---|---|---|
      | Calories | 110 kcal | 2,500 (2,390 to go) |
      | Protein | 2 g | 110 (108 to go) |
      | Fiber | 0.5 g | 20 (19.5 to go) |
      """

    @Test("A bot bubble that has room to spare stays as wide as the width its table lays out at")
    func bubbleMatchesTableLayoutWidth() {
      let content = TranscriptBotMessageContent(
        TranscriptBotMessage(id: "table", sender: .bot, text: table, sentAt: .distantPast))
      let natural = TranscriptBotMessageWidth.natural(of: content, theme: .default)
      let layoutWidth = natural - 40
      let proposedWidth = natural + 40

      let bubble = NSHostingController(
        rootView: Color.clear.frame(maxWidth: .infinity, minHeight: 20)
          .transcriptBotMessageWidth(fitting: content)
          .environment(\.streamMarkdownTextLayoutWidth, layoutWidth)
      )
      let size = bubble.sizeThatFits(in: CGSize(width: proposedWidth, height: 400))

      #expect(size.width == layoutWidth)
    }

    @Test("A table nested in a list item makes its bubble wide enough for the table and the item's indent")
    func nestedTableWidthIncludesListIndent() {
      let lone = TranscriptBotMessageContent(
        TranscriptBotMessage(id: "lone", sender: .bot, text: table, sentAt: .distantPast))
      let nestedText = "- Today:\n\n" + table.split(separator: "\n").map { "  \($0)" }.joined(separator: "\n")
      let nested = TranscriptBotMessageContent(
        TranscriptBotMessage(id: "nested", sender: .bot, text: nestedText, sentAt: .distantPast))

      #expect(
        TranscriptBotMessageWidth.natural(of: nested, theme: .default)
          >= TranscriptBotMessageWidth.natural(of: lone, theme: .default) + MarkdownFragmentMetrics.listIndent)
    }
  }
#endif
