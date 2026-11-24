import CoreGraphics
import Testing
@testable import StreamMarkdown

struct MarkdownTableGeometryTests {
  @Test func nativeViewportStaysBoundedInsideAnEnormousTable() {
    let bounds = CGRect(x: 0, y: 0, width: 402, height: 1_000_000)
    let visible = CGRect(x: 0, y: 900_000, width: 402, height: 800)
    let viewport = MarkdownTableGeometry.viewport(in: bounds, visible: visible)
    #expect(viewport == CGRect(x: 0, y: 899_920, width: 402, height: 960))
    #expect(MarkdownTableGeometry.viewport(in: bounds, visible: visible.offsetBy(dx: 500, dy: 0)) == viewport)
    #expect(
      MarkdownTableGeometry.viewport(in: bounds, visible: CGRect(x: 0, y: -100, width: 402, height: 800)).minY == 0)
    #expect(
      MarkdownTableGeometry.viewport(in: bounds, visible: CGRect(x: 0, y: 2_000_000, width: 402, height: 800)).isNull)
  }

  @Test func visibleWindowExcludesTouchingEdgesAndFindsDeepRows() {
    let geometry = MarkdownTableGeometry(
      columnWidths: [100, 200, 50], rowHeights: Array(repeating: 30, count: 20_000)
    )
    let viewport = CGRect(x: 100, y: 300_000, width: 200, height: 90)
    #expect(geometry.rows(intersecting: viewport) == 10_000..<10_003)
    #expect(geometry.columns(intersecting: viewport) == 1..<2)
    #expect(geometry.frame(row: 10_000, column: 1) == CGRect(x: 100, y: 300_000, width: 200, height: 30))
    #expect(geometry.rows(intersecting: CGRect(x: 0, y: -30, width: 100, height: 30)).isEmpty)
    #expect(geometry.rows(intersecting: CGRect(x: 0, y: 600_000, width: 100, height: 30)).isEmpty)
  }

  @Test func everyRowButTheLastHasARuleAlongItsBottomEdge() {
    let chrome = MarkdownTableChrome(
      geometry: MarkdownTableGeometry(columnWidths: [100, 60], rowHeights: [30, 40, 50]))
    let everything = CGRect(x: 0, y: 0, width: 160, height: 120)
    #expect(
      chrome.rules(intersecting: everything)
        == [CGRect(x: 0, y: 29, width: 160, height: 1), CGRect(x: 0, y: 69, width: 160, height: 1)])
    #expect(chrome.headerFrame == CGRect(x: 0, y: 0, width: 160, height: 30))
  }

  @Test func aRedrawOnlyGetsTheRulesOfTheRowsItTouches() {
    let chrome = MarkdownTableChrome(
      geometry: MarkdownTableGeometry(columnWidths: [100], rowHeights: Array(repeating: 30, count: 20_000)))
    let strip = CGRect(x: 0, y: 300_029, width: 100, height: 1)
    #expect(chrome.rules(intersecting: strip) == [CGRect(x: 0, y: 300_029, width: 100, height: 1)])
    #expect(chrome.rules(intersecting: CGRect(x: 0, y: 599_990, width: 100, height: 10)).isEmpty)
  }

  @Test func aSliverThinnerThanHalfAPointStillCoversOneTile() {
    #expect(MarkdownTableGeometry.tiles(from: 0, to: 0.3, tileLength: 384) == 0...0)
    #expect(MarkdownTableGeometry.tiles(from: 384.1, to: 384.3, tileLength: 384) == 1...1)
    #expect(MarkdownTableGeometry.tiles(from: 100, to: 800, tileLength: 384) == 0...2)
    #expect(MarkdownTableGeometry.tiles(from: 0, to: 384, tileLength: 384) == 0...0)
  }
}
