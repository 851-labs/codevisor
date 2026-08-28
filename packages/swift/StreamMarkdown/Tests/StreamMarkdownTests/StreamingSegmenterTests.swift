import Foundation
import Testing
@testable import StreamMarkdown

/// Every streaming snapshot is a complete MD4C parse. These tests protect the
/// segment shaping and prefix-reconciliation layer around that parse.
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
    /// step, and identical block segmentation after the finalize flip.
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
        // the preceding paragraph, proving every snapshot is parsed in full.
        assertStreamingEquivalence("intro text\n#not a heading, actually", chunkSize: 11)
    }

    @Test("A paragraph followed by a delimiter row becomes a table")
    func tableConversionEquivalence() {
        assertStreamingEquivalence("before\n\na | b\n--- | ---\n1 | 2", chunkSize: 7)
    }

    @Test("Text appended after a trailing blank line does not rejoin the paragraph")
    func paragraphBoundary() {
        let segmenter = StreamingSegmenter()
        _ = segmenter.segments(for: "para\n\n", isComplete: false)
        let segments = segmenter.segments(for: "para\n\nnext", isComplete: false)
        #expect(blocks(of: segments) == [.paragraph("para"), .paragraph("next")])
    }

    @Test("Blank lines inside an open code fence remain part of the code block")
    func openFenceRemainsWhole() {
        let document = "```\nline one\n\nline two\n\nline three"
        let segmenter = StreamingSegmenter()
        var streamed = ""
        for character in document {
            streamed.append(character)
            let segments = segmenter.segments(for: streamed, isComplete: false)
            #expect(blocks(of: segments) == parser.parse(streamed))
        }
    }

    @Test("Finalization preserves streaming block topology")
    func finalizationPreservesShape() {
        let segmenter = StreamingSegmenter()
        let text = "one\n\ntwo\n\nthree"
        let streaming = segmenter.segments(for: text, isComplete: false)
        #expect(streaming.count == 3)
        let finalized = segmenter.segments(for: text, isComplete: true)
        #expect(finalized == streaming)
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
            case let .paragraph(oldText) = oldBlocks[0], case let .paragraph(newText) = newBlocks[0],
            case let .text(oldStorage) = oldText.spans.first,
            case let .text(newStorage) = newText.spans.first
        {
            #expect(
                oldStorage.utf8.withContiguousStorageIfAvailable { $0.baseAddress }
                    == newStorage.utf8.withContiguousStorageIfAvailable { $0.baseAddress })
        } else {
            Issue.record("expected leading text runs")
        }
    }

    @Test("A rewritten non-prefix snapshot replaces the previous result")
    func rewriteReplacesPreviousResult() {
        let segmenter = StreamingSegmenter()
        _ = segmenter.segments(for: "first candidate answer", isComplete: false)
        let segments = segmenter.segments(for: "different text", isComplete: false)
        #expect(blocks(of: segments) == [.paragraph("different text")])
    }

    @Test("Multi-byte characters split across chunk boundaries survive")
    func multibyteChunks() {
        assertStreamingEquivalence("emoji 👩‍👩‍👧‍👦 and accents éü\n\nnext 🎛️ paragraph", chunkSize: 1)
    }

    @Test("Async parsing discards an out-of-order stale snapshot")
    func staleAsyncSnapshot() async {
        let coordinator = StreamingMarkdownParseCoordinator(
            text: "initial",
            isComplete: false,
            snapshotParser: { text, _ in
                if text == "slow" { Thread.sleep(forTimeInterval: 0.05) }
                return [.textRun([.paragraph(text)])]
            }
        )

        async let slow: Void = coordinator.update(text: "slow", isComplete: false)
        await Task.yield()
        await coordinator.update(text: "fast", isComplete: false)
        _ = await slow

        #expect(coordinator.presentation.text == "fast")
        #expect(coordinator.presentation.segments == [.textRun([.paragraph("fast")])])
    }

}
