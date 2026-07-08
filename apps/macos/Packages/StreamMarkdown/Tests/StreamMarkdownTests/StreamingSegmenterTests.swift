import Foundation
import Testing
@testable import StreamMarkdown

/// The segmenter's incremental streaming path must produce, at every prefix,
/// exactly the blocks a full parse of that prefix produces — the settled-cut
/// optimization is only allowed to change *when* text is parsed, never what
/// it parses to.
@MainActor
@Suite("StreamingSegmenter")
struct StreamingSegmenterTests {
    private let parser = MarkdownParser()

    /// Blocks rendered by a segment list (unwraps both segment shapes).
    private func blocks(of segments: [MarkdownSegment]) -> [MarkdownBlock] {
        segments.flatMap { segment -> [MarkdownBlock] in
            switch segment {
            case let .textRun(runBlocks): return runBlocks
            case let .block(block): return [block]
            }
        }
    }

    /// Streams `document` into a fresh segmenter in fixed-size character
    /// chunks, asserting block-level equivalence with a full parse at every
    /// step, and merged-segment equivalence after the finalize flip.
    private func assertStreamingEquivalence(_ document: String, chunkSize: Int) {
        let segmenter = StreamingSegmenter()
        var streamed = ""
        var pending = Substring(document)
        while !pending.isEmpty {
            streamed += String(pending.prefix(chunkSize))
            pending = pending.dropFirst(chunkSize)
            let segments = segmenter.segments(for: streamed, isComplete: false)
            #expect(
                blocks(of: segments) == parser.parse(streamed),
                "diverged at prefix length \(streamed.count) (chunk size \(chunkSize))"
            )
        }
        let finalized = segmenter.segments(for: document, isComplete: true)
        #expect(finalized == MarkdownSegment.segments(from: parser.parse(document)))
    }

    private static let richDocument = """
    # Streaming report

    First paragraph with **bold** and `inline code` spans that runs a bit \
    long so multiple chunks land inside it.

    - bullet one
    - bullet two

    1. step one
    2. step two

    ```swift
    let value = 42

    print(value) // blank line above is inside the fence
    ```

    > a quote
    > spanning lines

    | Name | Role |
    | :--- | ---: |
    | Ann  | Lead |
    | Bob  | IC   |

    ---

    Closing paragraph after a thematic break.
    """

    @Test("Chunked streaming matches a full parse at every prefix", arguments: [1, 3, 7, 16, 64])
    func chunkedEquivalence(chunkSize: Int) {
        assertStreamingEquivalence(Self.richDocument, chunkSize: chunkSize)
    }

    @Test("A line that stops looking like a heading rejoins the paragraph")
    func headingTrapEquivalence() {
        // "#" alone parses as an empty heading; once it grows into "#not a
        // heading" the line is paragraph content and must merge back into
        // the preceding paragraph — proving un-settled blocks re-parse.
        assertStreamingEquivalence("intro text\n#not a heading, actually", chunkSize: 11)
    }

    @Test("A paragraph followed by a delimiter row becomes a table")
    func tableConversionEquivalence() {
        assertStreamingEquivalence("before\n\na | b\n--- | ---\n1 | 2", chunkSize: 7)
    }

    @Test("Text appended after a trailing blank line does not rejoin the paragraph")
    func settledParagraphBoundary() {
        let segmenter = StreamingSegmenter()
        _ = segmenter.segments(for: "para\n\n", isComplete: false)
        let segments = segmenter.segments(for: "para\n\nnext", isComplete: false)
        #expect(blocks(of: segments) == [.paragraph("para"), .paragraph("next")])
    }

    @Test("Blank lines inside an open code fence never settle a cut")
    func openFenceBlocksSettling() {
        let document = "```\nline one\n\nline two\n\nline three"
        let segmenter = StreamingSegmenter()
        var streamed = ""
        for character in document {
            streamed.append(character)
            let segments = segmenter.segments(for: streamed, isComplete: false)
            #expect(blocks(of: segments) == parser.parse(streamed))
        }
    }

    @Test("Streaming segments render one block per segment; finalize merges runs")
    func mergeShape() {
        let segmenter = StreamingSegmenter()
        let text = "one\n\ntwo\n\nthree"
        let streaming = segmenter.segments(for: text, isComplete: false)
        #expect(streaming.count == 3)
        let finalized = segmenter.segments(for: text, isComplete: true)
        // Three consecutive text blocks merge into a single selectable run.
        #expect(finalized == [.textRun([.paragraph("one"), .paragraph("two"), .paragraph("three")])])
    }

    @Test("Settled segments keep their instances across flushes")
    func pointerStability() {
        let segmenter = StreamingSegmenter()
        // Long enough to be heap-allocated: small strings store their bytes
        // inline, so only heap strings have a stable base address to compare
        // (they are also the only case where stability matters).
        let settled = "a settled paragraph long enough for heap string storage"
        let first = segmenter.segments(for: settled + "\n\nbeta", isComplete: false)
        let second = segmenter.segments(for: settled + "\n\nbeta grows", isComplete: false)
        // Equal values, and the settled prefix must be the same instances the
        // previous flush returned (SwiftUI diffs String storage pointers).
        #expect(first.first == second.first)
        if case let .textRun(oldBlocks) = first[0], case let .textRun(newBlocks) = second[0],
           case let .paragraph(oldText) = oldBlocks[0], case let .paragraph(newText) = newBlocks[0] {
            #expect(oldText.utf8.withContiguousStorageIfAvailable { $0.baseAddress }
                == newText.utf8.withContiguousStorageIfAvailable { $0.baseAddress })
        } else {
            Issue.record("expected leading text runs")
        }
    }

    @Test("A rewritten (non-prefix) text resets the incremental state")
    func rewriteResets() {
        let segmenter = StreamingSegmenter()
        _ = segmenter.segments(for: "first candidate answer", isComplete: false)
        let segments = segmenter.segments(for: "different text", isComplete: false)
        #expect(blocks(of: segments) == [.paragraph("different text")])
    }

    @Test("Multi-byte characters split across chunk boundaries survive")
    func multibyteChunks() {
        assertStreamingEquivalence("emoji 👩‍👩‍👧‍👦 and accents éü\n\nnext 🎛️ paragraph", chunkSize: 1)
    }

    @Test("utf8Suffix returns the appended delta and rejects non-prefixes")
    func utf8Suffix() {
        #expect(StreamingSegmenter.utf8Suffix(of: "hello world", after: "hello") == " world")
        #expect(StreamingSegmenter.utf8Suffix(of: "hello", after: "hello") == "")
        #expect(StreamingSegmenter.utf8Suffix(of: "hello", after: "help") == nil)
        #expect(StreamingSegmenter.utf8Suffix(of: "hi", after: "hello") == nil)
    }

    @Test("settledCut ignores the final line, blanks inside blocks, and all-content tails")
    func settledCutRules() {
        // Final line can still grow: no cut in "para\n" (lines: para, "").
        #expect(StreamingSegmenter.settledCut(
            lines: ["para", ""],
            blocks: parser.parseBlocks("para\n")
        ) == nil)
        // A blank between two settled paragraphs is a cut.
        #expect(StreamingSegmenter.settledCut(
            lines: ["a", "", "b", "more"],
            blocks: parser.parseBlocks("a\n\nb\nmore")
        ) == 1)
        // The blank inside an open fence is fence content, not a cut.
        #expect(StreamingSegmenter.settledCut(
            lines: ["```", "code", "", "tail"],
            blocks: parser.parseBlocks("```\ncode\n\ntail")
        ) == nil)
    }
}
