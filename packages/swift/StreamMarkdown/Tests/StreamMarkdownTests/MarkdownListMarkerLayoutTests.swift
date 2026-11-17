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

  @Test(arguments: ["- One\n- Two", "1. One\n2. Two", "- [ ] One\n- [x] Two", "- One\n\n  More\n- Two"])
  func everyListShapeSharesOneHangingIndent(source: String) throws {
    let theme = MarkdownTheme()
    let text = MarkdownTextRunRenderer.attributedString(
      for: MarkdownParser().parse(source), theme: theme, foregroundColor: theme.textForeground)
    let location = (text.string as NSString).range(of: "One").location
    try #require(location != NSNotFound)
    let paragraph = try #require(
      text.attribute(.paragraphStyle, at: location, effectiveRange: nil) as? NSParagraphStyle)
    #expect(paragraph.headIndent == MarkdownFragmentMetrics.listIndent)
    #expect(paragraph.tabStops.first?.location == MarkdownFragmentMetrics.listIndent)
  }

  @Test("A quote nested in a list item draws its bar under the item's text, right of the item's marker")
  func quoteInsideListItemSitsInsideTheItem() throws {
    let fragments = MarkdownFragmentProjection.fragments(
      from: MarkdownParser().parse("- Item:\n\n  > ```\n  > let x = 1\n  > ```"))
    let item = try #require(fragments.first?.layout)
    let quoted = try #require(fragments.last?.layout)
    let marker = try #require(item.listMarkers.first)

    #expect(MarkdownFragmentMetrics.quoteBarOffset(at: 0, in: quoted) == MarkdownFragmentMetrics.listIndent)
    #expect(MarkdownFragmentMetrics.markerOffset(marker, in: item) < MarkdownFragmentMetrics.listIndent)
  }

  @Test("A list nested in a quote keeps its markers right of the quote bar")
  func listInsideQuoteSitsInsideTheQuote() throws {
    let fragments = MarkdownFragmentProjection.fragments(
      from: MarkdownParser().parse("> - Item:\n>\n>   ```\n>   let x = 1\n>   ```"))
    let item = try #require(fragments.first?.layout)
    let marker = try #require(item.listMarkers.first)

    #expect(MarkdownFragmentMetrics.quoteBarOffset(at: 0, in: item) == 0)
    #expect(MarkdownFragmentMetrics.markerOffset(marker, in: item) >= MarkdownFragmentMetrics.quoteIndent)
  }
}
