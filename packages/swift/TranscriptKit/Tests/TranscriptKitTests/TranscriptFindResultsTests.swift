import Testing
@testable import TranscriptKit

struct TranscriptFindResultsTests {
  private let rows = [
    TranscriptFindRowCount(rowKey: "a", count: 2),
    TranscriptFindRowCount(rowKey: "b", count: 0),
    TranscriptFindRowCount(rowKey: "c", count: 1),
  ]

  @Test func newSearchStartsAtTheViewportAndFallsBackToTheNearestMatchAbove() {
    #expect(TranscriptFindResults(rows: rows, startingRow: 1).current == .init(rowKey: "c", ordinal: 0))
    #expect(TranscriptFindResults(rows: rows, startingRow: 3).current == .init(rowKey: "c", ordinal: 0))
    #expect(
      TranscriptFindResults(rows: Array(rows.prefix(2)), startingRow: 2).current
        == .init(rowKey: "a", ordinal: 1))
    #expect(TranscriptFindResults(rows: [.init(rowKey: "a", count: 0)], startingRow: 0).current == nil)
  }

  @Test func steppingWrapsAtBothEnds() {
    var results = TranscriptFindResults(rows: rows, startingRow: 0)
    results.step(by: -1)
    #expect(results.current == .init(rowKey: "c", ordinal: 0))
    results.step(by: 1)
    #expect(results.current == .init(rowKey: "a", ordinal: 0))
  }

  @Test func streamingKeepsTheCurrentMatchOrLandsAtTheSamePosition() {
    var results = TranscriptFindResults(rows: rows, startingRow: 0)
    results.step(by: 1)
    // A new row streams in above; the bar stays on the same occurrence.
    results.update(rows: [.init(rowKey: "new", count: 3)] + rows)
    #expect(results.current == .init(rowKey: "a", ordinal: 1))
    #expect(results.currentIndex == 4)
    // That occurrence disappears; the bar lands on whatever now sits there.
    results.update(rows: [.init(rowKey: "a", count: 1), .init(rowKey: "c", count: 2)])
    #expect(results.current == .init(rowKey: "c", ordinal: 1))
  }
}
