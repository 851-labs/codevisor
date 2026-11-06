import Testing
@testable import CodevisorUI

struct RecentPagesTests {
  @Test("Showing a known page updates its route in place without reordering")
  func showingKnownPageKeepsOrder() {
    var recent = RecentPages<String, Int>(capacity: 3)
    recent.show(1, in: "a")
    recent.show(2, in: "b")
    recent.show(3, in: "a")

    #expect(recent.pages.map(\.id) == ["a", "b"])
    #expect(recent.pages.map(\.route) == [3, 2])
  }

  @Test("Overflow evicts the least recently shown page, not the first one added")
  func overflowEvictsLeastRecentlyShown() {
    var recent = RecentPages<String, Int>(capacity: 2)
    recent.show(1, in: "a")
    recent.show(2, in: "b")
    recent.show(3, in: "a")
    recent.show(4, in: "c")

    #expect(recent.pages.map(\.id) == ["a", "c"])
  }

  @Test("Previewing a page to show does not change the recorded pages")
  func previewLeavesHistoryUnchanged() {
    var recent = RecentPages<String, Int>(capacity: 2)
    recent.show(1, in: "a")

    #expect(recent.pages(showing: 2, in: "b").map(\.id) == ["a", "b"])
    #expect(recent.pages(showing: nil, in: nil).map(\.id) == ["a"])
    #expect(recent.pages.map(\.id) == ["a"])
  }

  @Test("Overflow spares kept pages and evicts the oldest other page")
  func overflowSparesKeptPages() {
    var recent = RecentPages<String, Int>(capacity: 2)
    recent.show(1, in: "a")
    recent.show(2, in: "b")
    recent.show(3, in: "c", keeping: ["a"])

    #expect(recent.pages.map(\.id) == ["a", "c"])
  }

  @Test("The page being shown is never evicted, even when every other page is kept")
  func shownPageSurvivesKeptPages() {
    var recent = RecentPages<String, Int>(capacity: 2)
    recent.show(1, in: "a")
    recent.show(2, in: "b")
    recent.show(3, in: "c", keeping: ["a", "b"])

    #expect(recent.pages.map(\.id) == ["a", "b", "c"])
  }
}
