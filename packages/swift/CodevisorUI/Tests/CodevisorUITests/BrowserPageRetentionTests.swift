import Foundation
import Testing
@testable import CodevisorUI

@MainActor
private final class RetainedPageFixture: RetainedBrowserPage {
  var hasLiveBrowserPage = true
  var protectsBrowserPage = false
  var allowsDiscard = true
  var discards = 0
  func discardBrowserPage() async -> Bool {
    guard allowsDiscard else { return false }
    hasLiveBrowserPage = false
    discards += 1
    return true
  }
}

@MainActor
@Suite("Browser live-page retention")
struct BrowserPageRetentionTests {
  @Test func aMemoryWarningDiscardsOnlyTheLeastRecentlyUsedTab() async {
    let retention = BrowserPageRetention(observesMemoryPressure: false)
    let pages = (0..<20).map { _ in RetainedPageFixture() }
    for page in pages { retention.touch(page) }
    retention.touch(pages[0])
    await retention.relieve(.warning)
    #expect(pages.map(\.discards) == [0, 1] + Array(repeating: 0, count: 18))
  }

  @Test func criticalPressureNeverEvictsProtectedOrBusyPages() async {
    let retention = BrowserPageRetention(observesMemoryPressure: false)
    let selected = RetainedPageFixture()
    selected.protectsBrowserPage = true
    let editing = RetainedPageFixture()
    editing.allowsDiscard = false
    let idle = RetainedPageFixture()
    let removed = RetainedPageFixture()
    for page in [selected, editing, idle, removed] { retention.touch(page) }
    retention.remove(removed)
    await retention.relieve(.critical)
    #expect(!idle.hasLiveBrowserPage)
    #expect(selected.hasLiveBrowserPage && editing.hasLiveBrowserPage && removed.hasLiveBrowserPage)
  }
}
