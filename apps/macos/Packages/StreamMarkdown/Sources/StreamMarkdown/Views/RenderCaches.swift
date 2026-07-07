import SwiftUI

/// Process-level render caches.
///
/// Transcript rows live in a `LazyVStack`, which destroys a row's `@State`
/// when it scrolls out of the viewport buffer and recreates it when it comes
/// back. Per-view memo caches therefore only help while an identity stays
/// mounted (streaming re-renders) — they are defeated by scrolling, where
/// every re-entering row used to re-parse its whole message on the main
/// thread. These shared LRUs are keyed by full content (never by hash alone:
/// a hash collision would render the wrong text), so re-entry is a
/// dictionary hit.

/// Parsed segments for recently rendered markdown texts.
@MainActor
public final class MarkdownSegmentCache {
    public static let shared = MarkdownSegmentCache()

    private let parser = MarkdownParser()
    private var entries: [String: [MarkdownSegment]] = [:]
    private var order: [String] = []
    private let limit: Int

    /// Streaming rewrites a message's text every flush, so intermediate texts
    /// pass through here once each; the LRU keeps the bound tight while the
    /// settled final texts — what scrolling re-encounters — stay hot.
    public init(limit: Int = 128) {
        self.limit = max(1, limit)
    }

    public func segments(for text: String) -> [MarkdownSegment] {
        if let cached = entries[text] {
            markUsed(text)
            return cached
        }
        let segments = MarkdownSegment.segments(from: parser.parse(text))
        store(segments, for: text)
        return segments
    }

    /// Test hook: whether a text is currently cached (observes LRU eviction).
    func isCached(_ text: String) -> Bool {
        entries[text] != nil
    }

    private func store(_ segments: [MarkdownSegment], for text: String) {
        entries[text] = segments
        order.append(text)
        if order.count > limit {
            entries.removeValue(forKey: order.removeFirst())
        }
    }

    private func markUsed(_ text: String) {
        guard order.last != text, let index = order.firstIndex(of: text) else { return }
        order.remove(at: index)
        order.append(text)
    }
}

/// Final highlighted `AttributedString`s for completed code blocks, readable
/// synchronously from `body` so a block scrolled back into view renders
/// colored on its first frame instead of flashing plain and re-laying-out
/// when the async highlighter catches up.
@MainActor
public final class CodeHighlightResultCache {
    public struct Key: Hashable, Sendable {
        public let themeKey: String
        public let language: String?
        public let code: String

        public init(themeKey: String, language: String?, code: String) {
            self.themeKey = themeKey
            self.language = language
            self.code = code
        }
    }

    public static let shared = CodeHighlightResultCache()

    private var entries: [Key: AttributedString] = [:]
    private var order: [Key] = []
    private let limit: Int

    public init(limit: Int = 100) {
        self.limit = max(1, limit)
    }

    public func value(for key: Key) -> AttributedString? {
        guard let cached = entries[key] else { return nil }
        markUsed(key)
        return cached
    }

    public func store(_ value: AttributedString, for key: Key) {
        if entries[key] == nil {
            order.append(key)
            if order.count > limit {
                entries.removeValue(forKey: order.removeFirst())
            }
        } else {
            markUsed(key)
        }
        entries[key] = value
    }

    private func markUsed(_ key: Key) {
        guard order.last != key, let index = order.firstIndex(of: key) else { return }
        order.remove(at: index)
        order.append(key)
    }
}
