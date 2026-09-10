#if canImport(AppKit)
  import AppKit
  import Testing
  @testable import StreamMarkdown

  struct MarkdownTableAccessibilityTests {
    @Test func bulkTextExportsStylesWithoutSerializingTableGraphs() {
      let paragraph = NSMutableParagraphStyle()
      paragraph.textBlocks = [
        NSTextTableBlock(table: NSTextTable(), startingRow: 0, rowSpan: 1, startingColumn: 0, columnSpan: 1)
      ]
      let text = NSAttributedString(
        string: "Before 日本語 after",
        attributes: [
          .font: NSFont.systemFont(ofSize: 15, weight: .semibold), .foregroundColor: NSColor.systemBlue,
          .paragraphStyle: paragraph, .strikethroughStyle: 1,
        ])
      let range = NSRange(location: 7, length: 3)
      let result = MarkdownTableAccessibility.attributedText(text, in: range)
      #expect(result?.string == "日本語")
      #expect(result?.attribute(.accessibilityFont, at: 0, effectiveRange: nil) != nil)
      #expect(result?.attribute(.accessibilityForegroundColor, at: 0, effectiveRange: nil) != nil)
      #expect(result?.attribute(.accessibilityStrikethrough, at: 0, effectiveRange: nil) as? Bool == true)
      #expect(result?.attribute(.paragraphStyle, at: 0, effectiveRange: nil) == nil)
      #expect(MarkdownTableAccessibility.attributedText(text, in: NSRange(location: text.length, length: 1)) == nil)
    }
  }
#endif
