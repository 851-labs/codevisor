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
    #expect(
      parser.parse("line one\nline two") == [
        .paragraph(MarkdownText(spans: [.text("line one"), .softBreak, .text("line two")]))
      ]
    )
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

  @Test("Parses bullet lists and honors marker changes")
  func bulletList() {
    let blocks = parser.parse("- a\n- b\n* c\n+ d")
    #expect(blocks == [.bulletList(["a", "b"]), .bulletList(["c"]), .bulletList(["d"])])
  }

  @Test("Parses ordered lists with CommonMark delimiter boundaries")
  func orderedList() {
    let blocks = parser.parse("1. first\n2. second\n10) tenth")
    #expect(
      blocks == [
        .orderedList([
          OrderedListItem(number: 1, text: "first"),
          OrderedListItem(number: 2, text: "second"),
        ]),
        .orderedList([OrderedListItem(number: 10, text: "tenth")]),
      ])
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
    #expect(
      blocks == [
        .blockQuote([
          .paragraph(MarkdownText(spans: [.text("quoted text"), .softBreak, .text("more")]))
        ])
      ]
    )
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
    #expect(
      blocks == [
        .table(
          headers: ["Name", "Age", "City"],
          alignments: [.leading, .center, .trailing],
          rows: [["Ann", "30", "NYC"], ["Bob", "25", "LA"]]
        )
      ])
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
    #expect(
      blocks == [
        .heading(level: 1, text: "Title"),
        .paragraph("Intro paragraph."),
        .bulletList(["one", "two"]),
        .codeBlock(language: nil, code: "code", isComplete: true),
        .paragraph("Done."),
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

  @Test("Resolves reference links using the complete document")
  func referenceLinks() {
    let blocks = parser.parse(
      "Read [the guide][docs].\n\n[docs]: <https://example.com/guide?a=1&amp;b=2>"
    )
    guard case let .paragraph(text) = blocks.first else {
      Issue.record("expected a paragraph")
      return
    }
    let attributed = InlineMarkdown.attributedString(from: text)
    #expect(String(attributed.characters) == "Read the guide.")
    #expect(
      attributed.runs.contains {
        $0.link?.absoluteString == "https://example.com/guide?a=1&b=2"
      }
    )
  }

  @Test("Retains nested and task list structure")
  func recursiveTaskList() {
    let blocks = parser.parse("- [x] shipped\n  - nested\n- [ ] pending")
    guard case let .list(list) = blocks.first else {
      Issue.record("expected a recursive list")
      return
    }
    #expect(list.items.count == 2)
    #expect(list.items[0].isTask)
    #expect(list.items[0].isChecked)
    #expect(list.items[0].blocks.count == 2)
    #expect(list.items[1].isTask)
    #expect(!list.items[1].isChecked)
  }

  @Test("Decodes numeric and HTML5 named entities")
  func entities() {
    guard case let .paragraph(text) = parser.parse("&euro; &#x1F642; &NotEqualTilde;").first else {
      Issue.record("expected a paragraph")
      return
    }
    #expect(text.plainText == "€ 🙂 ≂̸")
  }

  @Test("Treats raw HTML as text")
  func htmlIsText() {
    guard case let .paragraph(text) = parser.parse("<b>safe</b>").first else {
      Issue.record("expected literal HTML text")
      return
    }
    #expect(text.plainText == "<b>safe</b>")
  }

  @Test("Detects incomplete fences inside block quotes")
  func quotedFenceCompletion() {
    let open = parser.parse("> ```swift\n> let value = 1")
    guard case let .blockQuote(openBlocks) = open.first,
      case let .codeBlock(_, _, openComplete) = openBlocks.first
    else {
      Issue.record("expected quoted code")
      return
    }
    #expect(!openComplete)

    let closed = parser.parse("> ```swift\n> let value = 1\n> ```")
    guard case let .blockQuote(closedBlocks) = closed.first,
      case let .codeBlock(_, _, closedComplete) = closedBlocks.first
    else {
      Issue.record("expected quoted code")
      return
    }
    #expect(closedComplete)
  }

  @Test("Detects incomplete fences in ordered-list and quote containers")
  func nestedContainerFenceCompletion() {
    let open = parser.parse("1. > ```swift\n   > let value = 1")
    guard case let .list(openList) = open.first,
      case let .blockQuote(openBlocks) = openList.items.first?.blocks.first,
      case let .codeBlock(_, _, openComplete) = openBlocks.first
    else {
      Issue.record("expected fenced code in an ordered-list quote")
      return
    }
    #expect(!openComplete)

    let closed = parser.parse("1. > ```swift\n   > let value = 1\n   > ```")
    guard case let .list(closedList) = closed.first,
      case let .blockQuote(closedBlocks) = closedList.items.first?.blocks.first,
      case let .codeBlock(_, _, closedComplete) = closedBlocks.first
    else {
      Issue.record("expected closed fenced code in an ordered-list quote")
      return
    }
    #expect(closedComplete)
  }
}
