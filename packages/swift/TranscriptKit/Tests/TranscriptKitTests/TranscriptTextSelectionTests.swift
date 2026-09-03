import Foundation
import Testing
@testable import TranscriptKit

struct TranscriptTextSelectionTests {
  private let order = ["a", "b", "c", "d"]
  private func rowIndex(_ key: String) -> Int? { order.firstIndex(of: key) }

  @Test func resolveOrdersEndpointsByRowSurfaceThenOffset() {
    let backwards = TranscriptTextSelection(
      anchor: .init(rowKey: "c", surface: 0, offset: 4),
      focus: .init(rowKey: "a", surface: 1, offset: 9)
    )
    let span = try! #require(backwards.resolve(rowIndex: rowIndex))
    #expect(span.start.rowKey == "a")
    #expect(span.startRow == 0)
    #expect(span.end.rowKey == "c")
    #expect(span.endRow == 2)

    let sameRow = TranscriptTextSelection(
      anchor: .init(rowKey: "b", surface: 1, offset: 0),
      focus: .init(rowKey: "b", surface: 0, offset: 12)
    )
    let sameRowSpan = try! #require(sameRow.resolve(rowIndex: rowIndex))
    #expect(sameRowSpan.start.surface == 0)
    #expect(sameRowSpan.end.surface == 1)

    let sameSurface = TranscriptTextSelection(
      anchor: .init(rowKey: "b", surface: 0, offset: 7),
      focus: .init(rowKey: "b", surface: 0, offset: 2)
    )
    let sameSurfaceSpan = try! #require(sameSurface.resolve(rowIndex: rowIndex))
    #expect(sameSurfaceSpan.start.offset == 2)
    #expect(sameSurfaceSpan.end.offset == 7)
    #expect(!sameSurfaceSpan.isEmpty)
  }

  @Test func resolveFailsWhenARowLeftTheLayout() {
    let selection = TranscriptTextSelection(
      anchor: .init(rowKey: "a", surface: 0, offset: 0),
      focus: .init(rowKey: "gone", surface: 0, offset: 0)
    )
    #expect(selection.resolve(rowIndex: rowIndex) == nil)
  }

  @Test func collapsedSelectionIsEmpty() {
    let point = TranscriptSelectionPoint(rowKey: "b", surface: 1, offset: 3)
    let span = try! #require(
      TranscriptTextSelection(anchor: point, focus: point).resolve(rowIndex: rowIndex))
    #expect(span.isEmpty)
  }

  @Test func surfaceRangesClipOnlyTheEndpointRows() {
    let span = TranscriptSelectionSpan(
      start: .init(rowKey: "a", surface: 1, offset: 3),
      startRow: 0,
      end: .init(rowKey: "c", surface: 0, offset: 2),
      endRow: 2
    )
    #expect(span.surfaceRanges(rowIndex: 0, surfaceLengths: [5, 10, 4]) == [nil, 3..<10, 0..<4])
    #expect(span.surfaceRanges(rowIndex: 1, surfaceLengths: [6, 7]) == [0..<6, 0..<7])
    #expect(span.surfaceRanges(rowIndex: 2, surfaceLengths: [5, 10]) == [0..<2, nil])
    #expect(span.surfaceRanges(rowIndex: 3, surfaceLengths: [5]) == [nil])
  }

  @Test func surfaceRangesWithinOneRowAndSurface() {
    let span = TranscriptSelectionSpan(
      start: .init(rowKey: "b", surface: 1, offset: 2),
      startRow: 1,
      end: .init(rowKey: "b", surface: 1, offset: 6),
      endRow: 1
    )
    #expect(span.surfaceRanges(rowIndex: 1, surfaceLengths: [4, 9, 3]) == [nil, 2..<6, nil])
  }

  @Test func rowEndAndRowStartSentinelsCoverWholeRows() {
    let span = TranscriptSelectionSpan(
      start: .rowStart("a"),
      startRow: 0,
      end: .rowEnd("b"),
      endRow: 1
    )
    #expect(span.surfaceRanges(rowIndex: 0, surfaceLengths: [3, 4]) == [0..<3, 0..<4])
    #expect(span.surfaceRanges(rowIndex: 1, surfaceLengths: [3, 4]) == [0..<3, 0..<4])

    // A selection that starts at the end of a row contributes nothing from it.
    let fromEnd = TranscriptSelectionSpan(
      start: .rowEnd("a"),
      startRow: 0,
      end: .rowEnd("b"),
      endRow: 1
    )
    #expect(fromEnd.surfaceRanges(rowIndex: 0, surfaceLengths: [3, 4]) == [nil, nil])
  }

  @Test func offsetsPastTheEndOfAShorterSurfaceAreClamped() {
    let span = TranscriptSelectionSpan(
      start: .init(rowKey: "a", surface: 0, offset: 8),
      startRow: 0,
      end: .init(rowKey: "a", surface: 0, offset: 20),
      endRow: 0
    )
    #expect(span.surfaceRanges(rowIndex: 0, surfaceLengths: [5]) == [nil])
    #expect(span.surfaceRanges(rowIndex: 0, surfaceLengths: [12]) == [8..<12])
  }

  @Test func textJoinsSurfacesAndRowsSkippingEmptyContributions() {
    let rows: [[String]] = [
      ["Hello world", "second surface"],
      [],  // a chrome row with no text
      ["```code```"],
      ["tail", ""],
    ]
    let span = TranscriptSelectionSpan(
      start: .init(rowKey: "a", surface: 0, offset: 6),
      startRow: 0,
      end: .init(rowKey: "d", surface: 1, offset: 0),
      endRow: 3
    )
    let text = TranscriptSelectionText.text(
      in: span,
      surfaceLengths: { rows[$0].map { ($0 as NSString).length } },
      substring: { row, surface, range in
        TranscriptSelectionText.substring(of: rows[row][surface], in: range)
      },
      rowSeparator: { $0 == 3 ? "\n" : "\n\n" }
    )
    #expect(text == "world\n\nsecond surface\n\n```code```\ntail")
  }

  @Test func substringToleratesOutOfRangeOffsets() {
    #expect(TranscriptSelectionText.substring(of: "abc", in: 1..<10) == "bc")
    #expect(TranscriptSelectionText.substring(of: "abc", in: 5..<10) == "")
    #expect(TranscriptSelectionText.substring(of: "abc", in: 0..<0) == "")
  }
}
