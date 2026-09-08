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
  @Test func recentTabsStayAliveUntilTheIdleDeadline() async {
    var elapsed = 0.0
    let cache = BrowserPageRetention(capacity: 2, idleLifetime: 1800, now: { elapsed }, automaticallyPrune: false)
    let page = RetainedPageFixture()
    cache.touch(page)
    elapsed = 1799
    await cache.prune()
    #expect(page.hasLiveBrowserPage)
    // Revisiting resets the idle deadline, including a full return to chat.
    cache.touch(page)
    elapsed = 1800
    await cache.prune()
    #expect(page.hasLiveBrowserPage)
    elapsed = 3599
    await cache.prune()
    #expect(!page.hasLiveBrowserPage)
    #expect(page.discards == 1)
  }

  @Test func pressureAndCapacityNeverEvictProtectedPages() async {
    var elapsed = 0.0
    let cache = BrowserPageRetention(capacity: 2, now: { elapsed }, automaticallyPrune: false)
    let selected = RetainedPageFixture()
    selected.protectsBrowserPage = true
    let old = RetainedPageFixture()
    let recent = RetainedPageFixture()
    for page in [selected, old, recent] { cache.touch(page); elapsed += 1 }
    await cache.prune()
    #expect(!old.hasLiveBrowserPage)
    #expect(recent.hasLiveBrowserPage)
    #expect(selected.hasLiveBrowserPage)
    await cache.prune(memoryPressure: true)
    #expect(!recent.hasLiveBrowserPage)
    #expect(selected.hasLiveBrowserPage)
  }

  @Test func busyPagesAndRemovedModelsAreNotDiscarded() async {
    let cache = BrowserPageRetention(capacity: 0, automaticallyPrune: false)
    let dirty = RetainedPageFixture()
    dirty.allowsDiscard = false
    let removed = RetainedPageFixture()
    cache.touch(dirty)
    cache.touch(removed)
    cache.remove(removed)
    await cache.prune(memoryPressure: true)
    #expect(dirty.discards == 0)
    #expect(removed.discards == 0)
  }
}
