import Foundation
import Testing
@testable import StreamMarkdown

@Suite("MarkdownParser")
struct MarkdownParserTests {
    private let parser = MarkdownParser()

    @Test("Parses headings of every level")
    func headings() {
        #expect(parser.parse("# One") == [.heading(level: 1, text: "One")])
        #expect(parser.parse("### Three") == [.heading(level: 3, text: "Three")])
        #expect(parser.parse("###### Six") == [.heading(level: 6, text: "Six")])
        // Seven hashes is not a heading.
        #expect(parser.parse("####### Nope") == [.paragraph("####### Nope")])
        // No space after hashes is not a heading.
        #expect(parser.parse("#NoSpace") == [.paragraph("#NoSpace")])
    }

    @Test("Parses a paragraph and joins soft-wrapped lines")
    func paragraph() {
        #expect(parser.parse("Hello world") == [.paragraph("Hello world")])
        #expect(parser.parse("line one\nline two") == [.paragraph("line one\nline two")])
    }

    @Test("Separates paragraphs on blank lines")
    func multipleParagraphs() {
        let blocks = parser.parse("First\n\nSecond")
        #expect(blocks == [.paragraph("First"), .paragraph("Second")])
    }

    @Test("Parses a complete fenced code block with language")
    func codeBlockComplete() {
        let blocks = parser.parse("```swift\nlet x = 1\n```")
        #expect(blocks == [.codeBlock(language: "swift", code: "let x = 1", isComplete: true)])
    }

    @Test("Parses an unterminated code block as incomplete")
    func codeBlockIncomplete() {
        let blocks = parser.parse("```\nstreaming code")
        #expect(blocks == [.codeBlock(language: nil, code: "streaming code", isComplete: false)])
    }

    @Test("Parses tilde fences")
    func tildeFence() {
        let blocks = parser.parse("~~~\ncode\n~~~")
        #expect(blocks == [.codeBlock(language: nil, code: "code", isComplete: true)])
    }

    @Test("Parses bullet lists")
    func bulletList() {
        let blocks = parser.parse("- a\n- b\n* c\n+ d")
        #expect(blocks == [.bulletList(["a", "b", "c", "d"])])
    }

    @Test("Parses ordered lists preserving numbers")
    func orderedList() {
        let blocks = parser.parse("1. first\n2. second\n10) tenth")
        #expect(blocks == [.orderedList([
            OrderedListItem(number: 1, text: "first"),
            OrderedListItem(number: 2, text: "second"),
            OrderedListItem(number: 10, text: "tenth")
        ])])
    }

    @Test("Parses thematic breaks")
    func thematicBreak() {
        #expect(parser.parse("---") == [.thematicBreak])
        #expect(parser.parse("***") == [.thematicBreak])
        #expect(parser.parse("___") == [.thematicBreak])
        #expect(parser.parse("- - -") == [.thematicBreak])
    }

    @Test("Parses block quotes recursively")
    func blockQuote() {
        let blocks = parser.parse("> quoted text\n> more")
        #expect(blocks == [.blockQuote([.paragraph("quoted text\nmore")])])
    }

    @Test("Parses a GFM table with alignments")
    func table() {
        let markdown = """
        | Name | Age | City |
        | :--- | :-: | ---: |
        | Ann  | 30  | NYC  |
        | Bob  | 25  | LA   |
        """
        let blocks = parser.parse(markdown)
        #expect(blocks == [.table(
            headers: ["Name", "Age", "City"],
            alignments: [.leading, .center, .trailing],
            rows: [["Ann", "30", "NYC"], ["Bob", "25", "LA"]]
        )])
    }

    @Test("Pads short table rows to the header width")
    func tableRaggedRows() {
        let markdown = "| A | B |\n| - | - |\n| only |"
        let blocks = parser.parse(markdown)
        guard case let .table(_, _, rows) = blocks[0] else { Issue.record("expected table"); return }
        #expect(rows == [["only", ""]])
    }

    @Test("Interleaves block types in document order")
    func mixedDocument() {
        let markdown = """
        # Title

        Intro paragraph.

        - one
        - two

        ```
        code
        ```

        Done.
        """
        let blocks = parser.parse(markdown)
        #expect(blocks == [
            .heading(level: 1, text: "Title"),
            .paragraph("Intro paragraph."),
            .bulletList(["one", "two"]),
            .codeBlock(language: nil, code: "code", isComplete: true),
            .paragraph("Done.")
        ])
    }

    @Test("Empty input yields no blocks")
    func empty() {
        #expect(parser.parse("") == [])
        #expect(parser.parse("\n\n") == [])
    }

    @Test("Blocks expose stable identities")
    func identities() {
        let blocks = parser.parse("# A\n\nB")
        #expect(Set(blocks.map(\.id)).count == 2)
        #expect(MarkdownBlock.thematicBreak.id == "hr")
    }
}
