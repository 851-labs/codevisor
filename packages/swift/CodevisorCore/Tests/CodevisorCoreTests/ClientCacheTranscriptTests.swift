import CodevisorClient
import Foundation
import Testing

@testable import CodevisorCore

@Suite("Client cache transcripts")
struct ClientCacheTranscriptTests {
  @Test("An opened chat, its older pages, and a later refresh read back as one contiguous transcript")
  func pagesStitchIntoOneWindow() async throws {
    let fixture = try ClientCacheFixture()
    defer { fixture.tearDown() }
    let cache = try fixture.makeCache()

    cache.recordOpenedTranscript(fixture.opened(10...14, cursor: 50, hasMore: true), chat: fixture.chat)
    cache.recordTranscriptPage(fixture.page(5...9, cursor: 50, hasMore: true), before: "10", chat: fixture.chat)
    cache.recordTranscriptPage(fixture.page(12...16, cursor: 60, hasMore: true), before: nil, chat: fixture.chat)
    await cache.flush()

    let cached = try fixture.cachedSequences(in: cache)
    #expect(cached.sequences == Array(5...16))
    #expect(cached.nextBefore == "5")
  }

  @Test("A refresh that no longer overlaps the cached items replaces them instead of leaving a gap")
  func nonOverlappingRefreshDropsOlderItems() async throws {
    let fixture = try ClientCacheFixture()
    defer { fixture.tearDown() }
    let cache = try fixture.makeCache()

    cache.recordOpenedTranscript(fixture.opened(10...14, cursor: 50, hasMore: true), chat: fixture.chat)
    cache.recordTranscriptPage(fixture.page(30...34, cursor: 90, hasMore: true), before: nil, chat: fixture.chat)
    await cache.flush()

    #expect(try fixture.cachedSequences(in: cache).sequences == Array(30...34))
  }

  @Test("Items the server dropped from the newest page are removed, and an older page arriving late is ignored")
  func refreshesRemoveDroppedItemsAndIgnoreStalePages() async throws {
    let fixture = try ClientCacheFixture()
    defer { fixture.tearDown() }
    let cache = try fixture.makeCache()

    cache.recordOpenedTranscript(fixture.opened(10...14, cursor: 50, hasMore: false), chat: fixture.chat)
    let rewritten = [13: "00000000-0000-4000-8000-999999999999"]
    cache.recordTranscriptPage(
      fixture.page(10...13, cursor: 60, hasMore: false, ids: rewritten), before: nil, chat: fixture.chat)
    cache.recordTranscriptPage(fixture.page(10...14, cursor: 55, hasMore: false), before: nil, chat: fixture.chat)
    await cache.flush()

    let page = try JSONDecoder().decode(
      ServerTranscriptPage.self, from: try #require(try cache.transcripts.page(of: fixture.chat)))
    #expect(page.items.map(\.sequence) == Array(10...13))
    #expect(page.items.last?.id == rewritten[13])
    #expect(page.eventCursor == 60)
    #expect(page.hasMore == false)
  }

  @Test("Older pages stop being cached once a chat holds the most items the cache keeps")
  func olderPagesStopAtTheItemLimit() async throws {
    let fixture = try ClientCacheFixture()
    defer { fixture.tearDown() }
    let cache = try fixture.makeCache()
    let newest = TranscriptCacheTables.maxItemsPerChat + 99

    cache.recordOpenedTranscript(
      fixture.opened(100...newest, cursor: 50, hasMore: true), chat: fixture.chat)
    cache.recordTranscriptPage(fixture.page(90...99, cursor: 50, hasMore: true), before: "100", chat: fixture.chat)
    await cache.flush()

    let cached = try fixture.cachedSequences(in: cache)
    #expect(cached.sequences.first == 100)
    #expect(cached.nextBefore == "100")
  }
}
