import Testing
@testable import TranscriptKit

struct TranscriptQuoteLocatorTests {
  @Test func quoteInsideOneSurfaceTargetsExactlyItsRange() throws {
    let rows = [TranscriptQuoteRowText(rowKey: "a", surfaces: ["Hello brave new world"], separatorBefore: "\n\n")]

    let selection = try #require(TranscriptQuoteLocator.selection(of: "brave new", in: rows))

    #expect(selection.anchor == .init(rowKey: "a", surface: 0, offset: 6))
    #expect(selection.focus == .init(rowKey: "a", surface: 0, offset: 15))
  }

  @Test func quoteSpanningRowsAndSurfacesEndsInTheLastPiece() throws {
    let rows = [
      TranscriptQuoteRowText(rowKey: "a", surfaces: ["Intro paragraph", "let x = 1"], separatorBefore: "\n\n"),
      TranscriptQuoteRowText(rowKey: "b", surfaces: ["Closing words here"], separatorBefore: "\n"),
    ]

    let selection = try #require(
      TranscriptQuoteLocator.selection(of: "paragraph\n\nlet x = 1\nClosing", in: rows))

    #expect(selection.anchor == .init(rowKey: "a", surface: 0, offset: 6))
    #expect(selection.focus == .init(rowKey: "b", surface: 0, offset: 7))
  }

  @Test func emptySurfacesKeepLaterSurfaceIndices() throws {
    let rows = [TranscriptQuoteRowText(rowKey: "a", surfaces: ["", "visible text"], separatorBefore: "\n\n")]

    let selection = try #require(TranscriptQuoteLocator.selection(of: "text", in: rows))

    #expect(selection.anchor == .init(rowKey: "a", surface: 1, offset: 8))
    #expect(selection.focus == .init(rowKey: "a", surface: 1, offset: 12))
  }

  @Test func whitespaceDifferencesStillFindTheQuote() throws {
    let rows = [
      TranscriptQuoteRowText(rowKey: "a", surfaces: ["first line"], separatorBefore: "\n\n"),
      TranscriptQuoteRowText(rowKey: "b", surfaces: ["second  line"], separatorBefore: "\n\n"),
    ]

    let selection = try #require(TranscriptQuoteLocator.selection(of: " line\nsecond line ", in: rows))

    #expect(selection.anchor == .init(rowKey: "a", surface: 0, offset: 6))
    #expect(selection.focus == .init(rowKey: "b", surface: 0, offset: 12))
  }

  @Test func missingQuoteHasNoTarget() {
    let rows = [TranscriptQuoteRowText(rowKey: "a", surfaces: ["Hello"], separatorBefore: "\n\n")]

    #expect(TranscriptQuoteLocator.selection(of: "Goodbye", in: rows) == nil)
    #expect(TranscriptQuoteLocator.selection(of: "   ", in: rows) == nil)
    #expect(TranscriptQuoteLocator.selection(of: "Hello", in: []) == nil)
  }
}
