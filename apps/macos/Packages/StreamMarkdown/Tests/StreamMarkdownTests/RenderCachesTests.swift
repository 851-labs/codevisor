import SwiftUI
import Testing
@testable import StreamMarkdown

@MainActor
@Suite("Render caches")
struct RenderCachesTests {
    @Test("MarkdownSegmentCache returns identical segments for repeated text")
    func segmentCacheHit() {
        let cache = MarkdownSegmentCache(limit: 4)
        let text = "# Title\n\nSome **bold** text.\n\n```swift\nlet x = 1\n```"
        let first = cache.segments(for: text)
        let second = cache.segments(for: text)
        #expect(first == second)
        #expect(first.count == 2) // text run + code block
    }

    @Test("MarkdownSegmentCache evicts least-recently-used entries at the limit")
    func segmentCacheEviction() {
        let cache = MarkdownSegmentCache(limit: 2)
        _ = cache.segments(for: "one")
        _ = cache.segments(for: "two")
        // Touch "one" so "two" becomes the eviction candidate.
        _ = cache.segments(for: "one")
        _ = cache.segments(for: "three")
        #expect(cache.isCached("one"))
        #expect(!cache.isCached("two"))
        #expect(cache.isCached("three"))
        // Evicted texts still parse correctly on the next request.
        #expect(cache.segments(for: "two").isEmpty == false)
    }

    @Test("CodeHighlightResultCache stores and retrieves by full content")
    func highlightCacheRoundTrip() {
        let cache = CodeHighlightResultCache(limit: 2)
        let key = CodeHighlightResultCache.Key(themeKey: "t", language: "swift", code: "let x = 1")
        #expect(cache.value(for: key) == nil)
        cache.store(AttributedString("styled"), for: key)
        #expect(cache.value(for: key) == AttributedString("styled"))
        // Same code under a different theme or language is a distinct entry.
        let otherTheme = CodeHighlightResultCache.Key(themeKey: "u", language: "swift", code: "let x = 1")
        #expect(cache.value(for: otherTheme) == nil)
    }

    @Test("CodeHighlightResultCache keeps recently used entries under eviction")
    func highlightCacheEviction() {
        let cache = CodeHighlightResultCache(limit: 2)
        let one = CodeHighlightResultCache.Key(themeKey: "t", language: nil, code: "1")
        let two = CodeHighlightResultCache.Key(themeKey: "t", language: nil, code: "2")
        let three = CodeHighlightResultCache.Key(themeKey: "t", language: nil, code: "3")
        cache.store(AttributedString("one"), for: one)
        cache.store(AttributedString("two"), for: two)
        // Touch `one`, making `two` least recently used.
        #expect(cache.value(for: one) != nil)
        cache.store(AttributedString("three"), for: three)
        #expect(cache.value(for: one) != nil)
        #expect(cache.value(for: two) == nil)
        #expect(cache.value(for: three) != nil)
    }

    @Test("Storing an existing key updates the value without growing the order")
    func highlightCacheRestore() {
        let cache = CodeHighlightResultCache(limit: 2)
        let key = CodeHighlightResultCache.Key(themeKey: "t", language: nil, code: "1")
        cache.store(AttributedString("a"), for: key)
        cache.store(AttributedString("b"), for: key)
        #expect(cache.value(for: key) == AttributedString("b"))
        // A second distinct key must still fit — re-storing didn't consume
        // an extra LRU slot.
        let other = CodeHighlightResultCache.Key(themeKey: "t", language: nil, code: "2")
        cache.store(AttributedString("c"), for: other)
        #expect(cache.value(for: key) != nil)
        #expect(cache.value(for: other) != nil)
    }
}
