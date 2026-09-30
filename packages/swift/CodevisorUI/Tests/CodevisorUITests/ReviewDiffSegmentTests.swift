import Testing
import TranscriptKit
@testable import CodevisorUI

@Suite("Review diff folding")
struct ReviewDiffSegmentTests {
  /// "r" for a visible run, "g" for a folded gap, with its line count.
  private func shape(_ segments: [ReviewDiffSegment]) -> [String] {
    segments.map { segment in
      switch segment {
      case let .rows(rows): "r\(rows.count)"
      case let .gap(gap): "g\(gap.rows.count)"
      }
    }
  }

  private func gaps(_ segments: [ReviewDiffSegment]) -> [ReviewDiffSegment.Gap] {
    segments.compactMap { if case let .gap(gap) = $0 { gap } else { nil } }
  }

  private func rows(lines: Int, changing changed: Set<Int>) -> [LineDiff.Row] {
    let old = (1...lines).map { "line \($0)" }
    let new = old.enumerated().map { changed.contains($0.offset + 1) ? "edited \($0.offset + 1)" : $0.element }
    return LineDiff.rows(old: old.joined(separator: "\n") + "\n", new: new.joined(separator: "\n") + "\n")
  }

  @Test(
    "Changes keep three lines of context; only runs of four or more fold",
    arguments: [
      // One change mid-file: leading and trailing context fold.
      (lines: 40, changed: [20], expected: ["g16", "r8", "g17"]),
      // Changes near both ends: nothing outside the context remains.
      (lines: 8, changed: [1, 8], expected: ["r10"]),
      // Hunks whose context meets stay one run; a lone leading line is
      // cheaper shown than folded.
      (lines: 20, changed: [5, 12], expected: ["r17", "g5"]),
    ] as [(lines: Int, changed: Set<Int>, expected: [String])]
  )
  func folding(lines: Int, changed: Set<Int>, expected: [String]) {
    #expect(shape(ReviewDiffSegment.segments(for: rows(lines: lines, changing: changed))) == expected)
  }

  @Test("Gaps know which end of the file they sit at and label the hunk below")
  func gapPlacementAndHunkHeaders() {
    let rows = rows(lines: 80, changing: [20, 60])
    let found = gaps(ReviewDiffSegment.segments(for: rows))

    #expect(found.map(\.isLeading) == [true, false, false])
    #expect(found.map(\.isTrailing) == [false, false, true])
    // Each hunk spans its change plus three lines either side.
    #expect(found.map(\.nextHunkHeader) == ["@@ -17,7 +17,7 @@", "@@ -57,7 +57,7 @@", nil])
  }

  @Test("Expanding opens a step from either end of the same gap, then the rest merges in")
  func stepwiseExpansion() throws {
    let rows = rows(lines: 120, changing: [10, 110])
    let middle = try #require(gaps(ReviewDiffSegment.segments(for: rows)).first { !$0.isLeading && !$0.isTrailing })
    #expect(middle.rows.count == 93)

    // "Show next lines" under the first hunk, then expand up above the next.
    var expansions = [middle.id: ReviewGapExpansion(top: ReviewDiffSegment.expandStep)]
    var folded = try #require(
      gaps(ReviewDiffSegment.segments(for: rows, expansions: expansions)).first { $0.id == middle.id })
    #expect(folded.rows.count == 73)
    #expect(folded.rows.first?.id == middle.rows[20].id)

    expansions[middle.id]?.bottom = ReviewDiffSegment.expandStep
    folded = try #require(
      gaps(ReviewDiffSegment.segments(for: rows, expansions: expansions)).first { $0.id == middle.id })
    #expect(folded.rows.count == 53)
    #expect(folded.rows.last?.id == middle.rows[72].id)

    // Opening past what's left shows the whole run, in order.
    expansions[middle.id]?.top = 100
    let all = ReviewDiffSegment.segments(for: rows, expansions: expansions)
    #expect(!gaps(all).contains { $0.id == middle.id })
    let shown = all.flatMap { segment -> [LineDiff.Row] in
      switch segment {
      case let .rows(rows): rows
      case let .gap(gap): gap.rows
      }
    }
    #expect(shown == rows)
  }
}
