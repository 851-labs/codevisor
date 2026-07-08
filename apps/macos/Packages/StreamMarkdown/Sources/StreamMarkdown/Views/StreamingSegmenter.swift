import Foundation

/// Incrementally computes the segment list for a (possibly streaming)
/// markdown text.
///
/// Static texts and finalized messages parse through the shared LRU and merge
/// consecutive text blocks into selectable runs, exactly as before. While a
/// message is still streaming (`isComplete == false`) two things change, both
/// so that per-flush work scales with the *growing tail* instead of the whole
/// accumulated document (which made streaming cost quadratic over a turn):
///
/// 1. **No text-run merging.** Merged runs made the "changed segment" the
///    entire document for prose-heavy messages: every ~16ms flush rebuilt one
///    giant AttributedString and re-ran CoreText layout over it. Mid-stream,
///    each block is its own segment, so only the block actually receiving
///    text re-renders. Cross-block text selection is briefly unavailable
///    mid-stream; the finalize pass restores it.
/// 2. **Settled-prefix parsing.** Only the text after the last *settled cut*
///    is re-parsed per flush. A settled cut is a blank line that is fully
///    streamed (not the final line, which can still grow) and not inside any
///    block's line range. Streamed text is append-only, so lines before the
///    final line are immutable, and every construct in `MarkdownParser`
///    terminates at a blank line — except code fences, which the range check
///    excludes — so no appended text can ever change a block that ended
///    before such a cut. Those blocks are parsed exactly once.
///
/// When `isComplete` flips to true for the same text, segments are recomputed
/// once through the merging path: a single full re-render at finalize buys
/// back whole-message selection (and populates the shared LRU for scrolling).
@MainActor
final class StreamingSegmenter {
    private let parser = MarkdownParser()

    private var lastText: String?
    private var lastIsComplete = true
    private var lastSegments: [MarkdownSegment] = []

    /// Segments for blocks that streaming can no longer change.
    private var settledSegments: [MarkdownSegment] = []
    /// The text after the last settled cut — the only part re-parsed per flush.
    private var pendingTail = ""

    func segments(for text: String, isComplete: Bool) -> [MarkdownSegment] {
        // O(1) in the common case: the same String instance flows down from
        // the model between flushes, and `==` short-circuits on identical
        // storage.
        if text == lastText, isComplete == lastIsComplete { return lastSegments }

        var segments: [MarkdownSegment]
        if isComplete {
            segments = MarkdownSegmentCache.shared.segments(for: text)
            settledSegments = []
            pendingTail = ""
        } else {
            segments = streamingSegments(for: text)
        }

        // Re-use the previous pass's instances for segments whose content is
        // unchanged. A fresh parse allocates new String storage for every
        // block, and SwiftUI's change detection compares stored properties
        // structurally (String storage pointers, not contents) — so without
        // this, EVERY segment of a streaming message would read as "changed"
        // on every ~16ms flush and the entire message would re-render
        // (AttributedString rebuild + CoreText layout + display list) 60× per
        // second. With pointer-stable prefixes, only the segment actually
        // receiving text re-renders. Settled segments compare in O(1) (same
        // instances); the comparison does real work only at the first
        // changed segment, where it stops.
        let shared = min(segments.count, lastSegments.count)
        var index = 0
        while index < shared, segments[index] == lastSegments[index] {
            segments[index] = lastSegments[index]
            index += 1
        }

        lastText = text
        lastIsComplete = isComplete
        lastSegments = segments
        return segments
    }

    private func streamingSegments(for text: String) -> [MarkdownSegment] {
        if let lastText, !lastIsComplete, !lastText.isEmpty,
           let delta = Self.utf8Suffix(of: text, after: lastText) {
            pendingTail += delta
        } else {
            // First streaming frame, or a rewrite (the final-answer candidate
            // switched spans, a replay restarted the text): the incremental
            // state no longer describes this text — rebuild from scratch.
            settledSegments = []
            pendingTail = text
        }

        let lines = pendingTail.components(separatedBy: "\n")
        var tail = parser.parseBlocks(lines: lines)

        // Advance the settled cut and move the blocks behind it out of the
        // per-flush re-parse. Settling only ever *shrinks* future work; when
        // no cut exists (e.g. inside an open code fence) the whole tail just
        // stays pending.
        if let cut = Self.settledCut(lines: lines, blocks: tail) {
            let settledCount = tail.prefix { $0.lineRange.upperBound <= cut }.count
            settledSegments.append(contentsOf: tail.prefix(settledCount).map { Self.segment(for: $0.block) })
            tail.removeFirst(settledCount)
            pendingTail = lines[(cut + 1)...].joined(separator: "\n")
        }

        return settledSegments + tail.map { Self.segment(for: $0.block) }
    }

    /// The largest line index that is (a) not the final line — the final line
    /// has no trailing newline yet and can still grow, (b) blank, and (c)
    /// outside every block's line range (a blank inside a range can only be
    /// code-fence content). Nil when no such line exists.
    static func settledCut(lines: [String], blocks: [ParsedBlock]) -> Int? {
        guard lines.count >= 2 else { return nil }
        var blockIndex = blocks.count - 1
        for candidate in stride(from: lines.count - 2, through: 0, by: -1) {
            guard lines[candidate].trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            // The last block starting at or before the candidate is the only
            // one that could span it (blocks are ordered and disjoint).
            while blockIndex >= 0, blocks[blockIndex].lineRange.lowerBound > candidate {
                blockIndex -= 1
            }
            if blockIndex < 0 || blocks[blockIndex].lineRange.upperBound <= candidate {
                return candidate
            }
        }
        return nil
    }

    /// One block per segment — the mid-stream shape (no run merging).
    private static func segment(for block: MarkdownBlock) -> MarkdownSegment {
        MarkdownSegment.isTextRunBlock(block) ? .textRun([block]) : .block(block)
    }

    /// The suffix of `text` after `prefix`, or nil when `text` does not start
    /// with `prefix`. Byte-wise on the UTF-8 views: `String.hasPrefix` walks
    /// grapheme clusters over the entire prefix — a large constant on a path
    /// that runs against the full accumulated text every flush.
    static func utf8Suffix(of text: String, after prefix: String) -> String? {
        let textBytes = text.utf8
        let prefixBytes = prefix.utf8
        guard textBytes.count >= prefixBytes.count else { return nil }
        var textIndex = textBytes.startIndex
        for byte in prefixBytes {
            guard textBytes[textIndex] == byte else { return nil }
            textIndex = textBytes.index(after: textIndex)
        }
        // Decoding from a byte offset is safe even when a chunk boundary
        // split a grapheme cluster: `prefix` is itself a valid String, so the
        // cut is at a scalar boundary, and appending the suffix to
        // `pendingTail` re-forms any split cluster.
        return String(decoding: textBytes[textIndex...], as: UTF8.self)
    }
}
