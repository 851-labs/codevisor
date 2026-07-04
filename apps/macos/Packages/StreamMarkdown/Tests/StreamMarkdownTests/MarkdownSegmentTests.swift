import Testing
@testable import StreamMarkdown

@Suite("MarkdownSegment")
struct MarkdownSegmentTests {
    @Test("Consecutive text blocks coalesce into one run")
    func consecutiveTextBlocksCoalesce() {
        let blocks: [MarkdownBlock] = [
            .heading(level: 1, text: "Title"),
            .paragraph("First"),
            .bulletList(["a", "b"]),
            .orderedList([OrderedListItem(number: 1, text: "one")]),
        ]
        let segments = MarkdownSegment.segments(from: blocks)
        #expect(segments == [.textRun(blocks)])
    }

    @Test("Non-text blocks split runs")
    func nonTextBlocksSplitRuns() {
        let code = MarkdownBlock.codeBlock(language: "swift", code: "let x = 1", isComplete: true)
        let blocks: [MarkdownBlock] = [
            .paragraph("Before"),
            .paragraph("Still before"),
            code,
            .paragraph("After"),
        ]
        let segments = MarkdownSegment.segments(from: blocks)
        #expect(segments == [
            .textRun([.paragraph("Before"), .paragraph("Still before")]),
            .block(code),
            .textRun([.paragraph("After")]),
        ])
    }

    @Test("Standalone non-text blocks stay standalone")
    func standaloneNonTextBlocks() {
        let table = MarkdownBlock.table(headers: ["h"], alignments: [.none], rows: [["r"]])
        let quote = MarkdownBlock.blockQuote([.paragraph("quoted")])
        let segments = MarkdownSegment.segments(from: [table, .thematicBreak, quote])
        #expect(segments == [.block(table), .block(.thematicBreak), .block(quote)])
    }

    @Test("Empty input produces no segments")
    func emptyInput() {
        #expect(MarkdownSegment.segments(from: []).isEmpty)
    }

    @Test("Text-run classification covers every case")
    func classification() {
        #expect(MarkdownSegment.isTextRunBlock(.heading(level: 2, text: "h")))
        #expect(MarkdownSegment.isTextRunBlock(.paragraph("p")))
        #expect(MarkdownSegment.isTextRunBlock(.bulletList(["i"])))
        #expect(MarkdownSegment.isTextRunBlock(.orderedList([OrderedListItem(number: 1, text: "i")])))
        #expect(!MarkdownSegment.isTextRunBlock(.codeBlock(language: nil, code: "c", isComplete: false)))
        #expect(!MarkdownSegment.isTextRunBlock(.blockQuote([.paragraph("q")])))
        #expect(!MarkdownSegment.isTextRunBlock(.table(headers: [], alignments: [], rows: [])))
        #expect(!MarkdownSegment.isTextRunBlock(.thematicBreak))
    }
}
