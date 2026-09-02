import CoreGraphics
import Foundation
import Testing
@testable import TranscriptKit

struct TranscriptDocumentGeometryTests {
  private typealias Row = TranscriptPresentationRow

  private func row(_ key: UUID = UUID(), height: CGFloat) -> Row {
    Row(id: .message(key), content: .error(""), estimatedHeight: height)
  }

  private func spacer(_ height: CGFloat) -> Row {
    Row(id: .bottomSpacer, content: .bottomSpacer(height), estimatedHeight: height)
  }

  private func layout(_ rows: [Row], measured: [String: CGFloat] = [:]) -> VirtualTranscriptLayout {
    var ledger = TranscriptMeasurementLedger()
    for (key, height) in measured { ledger.setExact(height, for: key) }
    return TranscriptDocumentGeometry.layout(rows: rows, measurements: ledger, spacing: 10)
  }

  // MARK: layout / incremental

  @Test func layoutUsesLedgerHeightsOverEstimates() {
    let a = row(height: 100)
    let b = row(height: 200)
    let built = layout([a, b], measured: [b.layoutKey: 250])
    #expect(built.heights == [100, 250])
    #expect(built.totalHeight == 360)
  }

  @Test func incrementalPatchRequiresHintMatchingRowSetAndKnownKeys() {
    let a = row(height: 100)
    let b = row(height: 200)
    let current = layout([a, b])
    #expect(TranscriptDocumentGeometry.incrementallyUpdatedLayout(current, rowCount: 2, changedHeights: nil) == nil)
    #expect(TranscriptDocumentGeometry.incrementallyUpdatedLayout(current, rowCount: 2, changedHeights: [:]) == nil)
    #expect(
      TranscriptDocumentGeometry.incrementallyUpdatedLayout(
        current, rowCount: 3, changedHeights: [a.layoutKey: 1])
        == nil)
    #expect(
      TranscriptDocumentGeometry.incrementallyUpdatedLayout(current, rowCount: 2, changedHeights: ["missing": 1])
        == nil)
    let patched = TranscriptDocumentGeometry.incrementallyUpdatedLayout(
      current, rowCount: 2, changedHeights: [a.layoutKey: 150]
    )
    #expect(patched?.heights == [150, 200])
    #expect(patched?.totalHeight == 360)
  }

  // MARK: spacer change

  @Test func bottomSpacerChangeComparesLedgerOrEstimateAgainstPreviousLayout() {
    let a = row(height: 100)
    let previous = layout([a, spacer(40)])
    var ledger = TranscriptMeasurementLedger()
    #expect(
      !TranscriptDocumentGeometry.bottomSpacerGeometryWillChange(
        from: previous, spacerRow: spacer(40), measurements: ledger))
    #expect(
      TranscriptDocumentGeometry.bottomSpacerGeometryWillChange(
        from: previous, spacerRow: spacer(70), measurements: ledger))
    ledger.setExact(40.2, for: Row.ID.bottomSpacer.layoutKey)
    #expect(
      !TranscriptDocumentGeometry.bottomSpacerGeometryWillChange(
        from: previous, spacerRow: spacer(70), measurements: ledger))
    #expect(
      !TranscriptDocumentGeometry.bottomSpacerGeometryWillChange(
        from: previous, spacerRow: nil, measurements: ledger))
    #expect(
      !TranscriptDocumentGeometry.bottomSpacerGeometryWillChange(
        from: layout([a]), spacerRow: spacer(70), measurements: ledger))
  }

  // MARK: rebuild plan

  private func plan(
    previous: VirtualTranscriptLayout,
    distance: CGFloat?,
    follows: Bool = false,
    locked: CGFloat? = nil,
    applied: Bool = true,
    gate: Bool = false,
    spacerChange: Bool = false,
    measured: [String: CGFloat] = [:]
  ) -> TranscriptGeometryRebuildPlan {
    var ledger = TranscriptMeasurementLedger()
    for (key, height) in measured { ledger.setExact(height, for: key) }
    return TranscriptGeometryRebuildPlan(
      previousLayout: previous,
      previousDistanceFromBottom: distance,
      viewportHeight: 300,
      followsLatest: follows,
      lockedRestoreDistance: locked,
      initialPositionApplied: applied,
      gatePinsBottom: gate,
      bottomSpacerWillChange: spacerChange,
      atBottomThreshold: 2,
      measurements: ledger
    )
  }

  @Test func planBeforeInitialPositionPreservesNothing() {
    let p = plan(previous: layout([row(height: 100)]), distance: nil, applied: false)
    #expect(p.distanceToPreserve == nil)
    #expect(p.visibleAnchorKey == nil)
    #expect(!p.pinsBottom)
  }

  @Test func planPinsBottomForGatesAndForSpacerChangesAtBottom() {
    let previous = layout([row(height: 100), row(height: 100)])
    #expect(plan(previous: previous, distance: 500, gate: true).pinsBottom)
    #expect(plan(previous: previous, distance: 1, spacerChange: true).pinsBottom)
    #expect(!plan(previous: previous, distance: 50, spacerChange: true).pinsBottom)
    let pinned = plan(previous: previous, distance: 500, gate: true)
    #expect(pinned.distanceToPreserve == 0)
    #expect(pinned.visibleAnchorKey == nil)
  }

  @Test func planFollowingLatestPinsBottomWithoutAnchor() {
    let p = plan(previous: layout([row(height: 100)]), distance: 400, follows: true)
    #expect(p.pinsBottom)
    #expect(p.distanceToPreserve == 0)
    #expect(p.visibleAnchorKey == nil)
  }

  /// A turn that starts and finishes while the chat is off screen appends
  /// settled rows with no active row. A reader who left at the bottom must
  /// come back to the bottom and stay there while those rows measure.
  @Test func followingReaderStaysAtBottomWhenSettledRowsAppendBelow() {
    let first = row(height: 100)
    let second = row(height: 100)
    let previous = layout([first, second], measured: [first.layoutKey: 100])
    let grown = layout([first, second, row(height: 40)])

    let following = plan(previous: previous, distance: 0, follows: true, measured: [first.layoutKey: 100])
    #expect(following.pinsBottom)
    #expect(following.resolvedDistanceFromBottom(newLayout: grown, previousLayout: previous) == 0)

    // The same change for a reader who scrolled up keeps their row stationary.
    let reading = plan(previous: previous, distance: 120, follows: false, measured: [first.layoutKey: 100])
    #expect(!reading.pinsBottom)
    #expect(reading.visibleAnchorKey == first.layoutKey)
  }

  @Test func lockedRestoreDistanceWinsOverEverything() {
    let p = plan(previous: layout([row(height: 100)]), distance: 400, follows: true, locked: 77, gate: true)
    #expect(p.distanceToPreserve == 77)
  }

  @Test func planPrefersMeasuredVisibleRowAsAnchorThenFirstVisible() {
    let a = row(height: 100)
    let b = row(height: 100)
    let c = row(height: 100)
    let d = row(height: 100)
    let previous = layout([a, b, c, d])  // total 430, spacing 10
    // Viewport 300 tall at distance 0 shows the bottom ~300pt: c and d (and part of b).
    let unmeasured = plan(previous: previous, distance: 0)
    #expect(unmeasured.visibleAnchorKey == b.layoutKey)
    #expect(unmeasured.distanceToPreserve == 0)
    let measured = plan(previous: previous, distance: 0, measured: [c.layoutKey: 100])
    #expect(measured.visibleAnchorKey == c.layoutKey)
  }

  @Test func resolvedDistanceKeepsAnchorStationaryWhenRowsAboveItGrow() {
    let a = row(height: 100)
    let b = row(height: 100)
    let c = row(height: 100)
    let previous = layout([a, b, c])
    let p = plan(previous: previous, distance: 0, measured: [c.layoutKey: 100])
    #expect(p.visibleAnchorKey == c.layoutKey)
    // Anchor below the growth: distance unchanged. Growth of `a` (above c) must not move c.
    let grownAbove = layout([a, b, c], measured: [a.layoutKey: 300, c.layoutKey: 100])
    #expect(p.resolvedDistanceFromBottom(newLayout: grownAbove, previousLayout: previous) == 0)
    // Growth below the anchor pushes the distance up by the delta.
    let grownBelow = layout([a, b, c, row(height: 50)], measured: [c.layoutKey: 100])
    #expect(p.resolvedDistanceFromBottom(newLayout: grownBelow, previousLayout: previous) == 60)
  }

  @Test func resolvedDistanceFallsBackWhenAnchorVanishesOrPinned() {
    let a = row(height: 100)
    let previous = layout([a])
    let p = plan(previous: previous, distance: 20)
    #expect(p.visibleAnchorKey == a.layoutKey)
    #expect(p.resolvedDistanceFromBottom(newLayout: layout([row(height: 100)]), previousLayout: previous) == 20)
    let pinned = plan(previous: previous, distance: 0, gate: true)
    #expect(
      pinned.resolvedDistanceFromBottom(newLayout: layout([a, row(height: 999)]), previousLayout: previous) == 0)
    let notApplied = plan(previous: previous, distance: nil, applied: false)
    #expect(notApplied.resolvedDistanceFromBottom(newLayout: previous, previousLayout: previous) == nil)
  }

  // MARK: layout surface helpers

  @Test func keysInRangeIgnoresOutOfBoundsIndices() {
    let a = row(height: 1)
    let b = row(height: 1)
    let l = layout([a, b])
    #expect(l.keys(in: -1..<5) == [a.layoutKey, b.layoutKey])
    #expect(l.keys(in: 1..<2) == [b.layoutKey])
    #expect(l.keys(in: 3..<3).isEmpty)
  }

  @Test func contiguousRangeRequiresKnownAdjacentKeys() {
    let rows = (0..<4).map { _ in row(height: 1) }
    let l = layout(rows)
    #expect(l.contiguousRange(of: []) == nil)
    #expect(l.contiguousRange(of: [rows[1].layoutKey, rows[2].layoutKey]) == 1..<3)
    #expect(l.contiguousRange(of: [rows[0].layoutKey, rows[2].layoutKey]) == nil)
    #expect(l.contiguousRange(of: [rows[0].layoutKey, "missing"]) == nil)
  }

  @Test func renderedWindowSpansFirstThroughLastKnownKey() {
    let rows = (0..<4).map { _ in row(height: 1) }
    let l = layout(rows)
    let window = l.renderedWindow(covering: [rows[3].layoutKey, rows[1].layoutKey, "missing"])
    #expect(window?.anchorKey == rows[1].layoutKey)
    #expect(window?.count == 3)
    #expect(l.renderedWindow(covering: ["missing"]) == nil)
  }

  @Test func readinessRequiresCommittedMeasurementAndReadyHost() {
    var ledger = TranscriptMeasurementLedger()
    ledger.setExact(10, for: "exact")
    ledger.setProvisional(10, for: "stale")
    let resolved = TranscriptMountedWindowReadiness.resolvedKeys(
      required: ["exact", "stale", "unmeasured", "hostNotReady"],
      measurements: ledger,
      isHostReady: { $0 != "hostNotReady" }
    )
    #expect(resolved == ["exact"])
  }
}
