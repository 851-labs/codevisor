import AppKit
import Testing
@testable import StreamMarkdown

@MainActor
struct MarkdownListMarkerLayoutTests {
  @Test func wideOrderedMarkersHaveRoomBeforeTheirTabStop() throws {
    let blocks = MarkdownParser().parse("> 9998. First\n> 9999. Second\n> 10000. Third")
    let theme = MarkdownTheme()
    let text = MarkdownTextRunRenderer.attributedString(
      for: blocks, theme: theme, foregroundColor: theme.textForeground)
    let source = text.string as NSString
    for marker in ["9998.", "9999.", "10000."] {
      let range = source.range(of: marker)
      #expect(range.location != NSNotFound)
      let font = try #require(text.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont)
      let paragraph = try #require(
        text.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle)
      let width = (marker as NSString).size(withAttributes: [.font: font]).width
      #expect(paragraph.headIndent - paragraph.firstLineHeadIndent >= width + 8)
    }
  }
}
