import CoreGraphics
import Testing
@testable import TranscriptKit

struct TranscriptHeightIndexTests {
  @Test func searchesRespectRowsGapsAndSubtreeBoundaries() {
    let rows: [TranscriptHeightIndex.Row] = (0..<257).map { position in
      let height = CGFloat(1 + position % 19)
      let spacing = position == 256 ? CGFloat.zero : CGFloat(position % 5)
      return TranscriptHeightIndex.Row(height: height, spacing: spacing)
    }
    let index = TranscriptHeightIndex(rows: rows)
    var top: CGFloat = 0
    for (position, row) in rows.enumerated() {
      let geometry = index.geometry(at: position)
      #expect(geometry.top == top)
      #expect(geometry.height == row.height)
      #expect(index.firstTopReaching(top) == position)
      #expect(index.firstBottomExceeding(top) == position)
      #expect(index.firstBottomExceeding(top + row.height - 0.25) == position)
      #expect(index.firstBottomExceeding(top + row.height) == min(position + 1, rows.count - 1))
      #expect(index.firstTopReaching(top + 0.25) == position + 1)
      top += row.extent
    }
    #expect(index.totalHeight == top)
    #expect(index.firstTopReaching(-100) == 0)
    #expect(index.firstTopReaching(top + 100) == rows.count)
  }

  @Test func batchedCorrectionsPreservePriorSnapshotsAndSpacing() {
    let rows = (0..<129).map {
      TranscriptHeightIndex.Row(height: CGFloat(10 + $0 % 9), spacing: $0 == 128 ? 0 : 3)
    }
    let initial = TranscriptHeightIndex(rows: rows)
    let updates: [(index: Int, height: CGFloat)] = [(128, 80), (0, 41), (32, 51), (64, 61)]
    let changed = initial.replacing(updates)
    var expected = rows
    for update in updates {
      expected[update.index] = .init(height: update.height, spacing: rows[update.index].spacing)
    }
    #expect(initial.allRows() == rows)
    #expect(changed.allRows() == expected)
    #expect(changed == TranscriptHeightIndex(rows: expected))
    #expect(changed.replacing(updates) == changed)
    var top: CGFloat = 0
    for (position, row) in expected.enumerated() {
      #expect(changed.geometry(at: position).top == top)
      top += row.extent
    }
  }

  @Test func pointCorrectionHasLogarithmicWorkWithRetainedSnapshot() {
    let count = 131_072
    let original = TranscriptHeightIndex(
      rows: (0..<count).map { .init(height: 20, spacing: $0 == count - 1 ? 0 : 4) }
    )
    let changed = original.replacing([(count / 2, 44)])
    // 4096 leaves, a depth of 12, and one visited leaf. This measures actual
    // update work even though an old geometry snapshot is still retained.
    #expect(changed.updatedNodeCount == 13)
    #expect(changed.totalHeight == original.totalHeight + 24)
    #expect(original.geometry(at: count / 2).height == 20)
    #expect(changed.geometry(at: count / 2).height == 44)
  }
}
