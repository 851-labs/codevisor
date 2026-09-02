import CoreGraphics
import Foundation
import Testing
@testable import TranscriptKit

/// Absolute cost of the extracted transcript-surface layer on a worst-case
/// row set. These are not regression gates — they print timings so the
/// per-frame overhead of TranscriptRowSet / geometry / window planning can be
/// bounded. Opt in with `BENCH=1 swift test --filter TranscriptSurfaceBenchmarks`
/// (optionally `-Xswiftc -O`); skipped otherwise so the ordinary test run and
/// the pre-commit hook stay fast.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["BENCH"] == "1"))
struct TranscriptSurfaceBenchmarks {
  private typealias Row = TranscriptPresentationRow

  /// Row count for the synthetic worst case; override with BENCH_ROWS.
  private static var rowCount: Int {
    Int(ProcessInfo.processInfo.environment["BENCH_ROWS"] ?? "") ?? 20_000
  }

  private static func rows(count: Int, activeSlices: Int) -> (projected: [Row], active: [Row]) {
    var projected: [Row] = []
    projected.reserveCapacity(count + 2)
    for index in 0..<count {
      let id = UUID()
      let content: Row.Content = index % 3 == 0 ? .backgroundTask("t\(index)") : .error("e\(index)")
      projected.append(
        Row(
          id: .assistantMarkdown(id, sourceID: "s", ordinal: index, fragment: nil),
          content: content,
          estimatedHeight: CGFloat(24 + (index % 7) * 18),
          measurementRevision: index % 5
        ))
    }
    let turn = UUID()
    projected.append(Row(id: .active(turn), content: .error(""), estimatedHeight: 120))
    projected.append(Row(id: .bottomSpacer, content: .bottomSpacer(96), estimatedHeight: 96))
    let active = (0..<activeSlices).map { ordinal in
      Row(
        id: .activeMarkdown(turn, sourceID: "a", ordinal: ordinal, fragment: nil),
        content: .error(""),
        estimatedHeight: CGFloat(20 + ordinal % 4 * 10)
      )
    }
    return (projected, active)
  }

  private static func measure(_ label: String, iterations: Int, _ body: () -> Void) {
    body()  // warm
    let start = DispatchTime.now().uptimeNanoseconds
    for _ in 0..<iterations { body() }
    let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
    let perIteration = elapsed / Double(iterations)
    let paddedLabel = label.padding(toLength: 48, withPad: " ", startingAt: 0)
    print("[bench] \(paddedLabel) \(String(format: "%9.3f", perIteration)) ms/iter  (\(iterations) iters)")
  }

  @Test func rowSetResolutionAndActiveReplacement() {
    let (projected, active) = Self.rows(count: Self.rowCount, activeSlices: 40)
    var set = TranscriptRowSet()
    set.projectedRows = projected
    _ = set.replaceActiveRows(active)
    set.replaceRows(TranscriptRowSet.resolve(projectedRows: projected, activeRows: active).rows)

    Self.measure("resolve 20k projected + 40 active", iterations: 50) {
      _ = TranscriptRowSet.resolve(projectedRows: projected, activeRows: active)
    }
    Self.measure("replaceRows 20k (rebuild key index)", iterations: 20) {
      var copy = set
      copy.replaceRows(projected)
    }
    var grown = active
    grown[grown.count - 1] = Row(
      id: grown.last!.id, content: .error("x"), estimatedHeight: grown.last!.estimatedHeight + 30
    )
    Self.measure("replaceActiveRows in place (token flush)", iterations: 200) {
      var copy = set
      _ = copy.replaceActiveRows(grown)
    }
    Self.measure("geometryChanged 20k identical", iterations: 200) {
      _ = set.geometryChanged(comparedTo: set.rows)
    }
    Self.measure("reversePrependCount 20k (+50 older)", iterations: 100) {
      _ = TranscriptRowSet.reversePrependCount(from: projected, to: Array(projected.prefix(50)) + projected)
    }
  }

  @Test func documentGeometryAndPlanning() {
    let (projected, active) = Self.rows(count: Self.rowCount, activeSlices: 40)
    let rows = TranscriptRowSet.resolve(projectedRows: projected, activeRows: active).rows
    var ledger = TranscriptMeasurementLedger()
    for (index, row) in rows.enumerated() where index % 2 == 0 {
      ledger.setExact(row.estimatedHeight + 3, for: row.layoutKey)
    }
    var layout = TranscriptDocumentGeometry.layout(rows: rows, measurements: ledger, spacing: 20)
    Self.measure("full layout 20k rows", iterations: 20) {
      layout = TranscriptDocumentGeometry.layout(rows: rows, measurements: ledger, spacing: 20)
    }
    let changed = Dictionary(uniqueKeysWithValues: rows.suffix(6).map { ($0.layoutKey, $0.estimatedHeight + 9) })
    Self.measure("incremental patch (6 heights) 20k rows", iterations: 100) {
      _ = TranscriptDocumentGeometry.incrementallyUpdatedLayout(
        layout, rowCount: rows.count, changedHeights: changed)
    }
    Self.measure("rebuild plan (anchor selection)", iterations: 500) {
      _ = TranscriptGeometryRebuildPlan(
        previousLayout: layout,
        previousDistanceFromBottom: 4_000,
        viewportHeight: 900,
        followsLatest: false,
        lockedRestoreDistance: nil,
        initialPositionApplied: true,
        gatePinsBottom: false,
        bottomSpacerWillChange: false,
        atBottomThreshold: 2,
        measurements: ledger
      )
    }
    let planner = TranscriptWindowPlanner(policy: TranscriptVirtualWindowPolicy(), initialRunwayViewportCount: 1.5)
    var target: Set<String> = []
    Self.measure("window plan per frame (scrolling)", iterations: 500) {
      let range = planner.plannedRange(
        layout: layout,
        distanceFromBottom: 4_000,
        viewportHeight: 900,
        scrollDelta: 120,
        isInitialPresentationReady: true,
        currentTargetKeys: target
      )
      let visible = layout.visibleRange(distanceFromBottom: 4_000, viewportHeight: 900, overscanCount: 0)
      target = TranscriptWindowPlanner.targetKeys(layout: layout, targetRange: range, visibleRange: visible)
    }
    Self.measure("readiness over 60-row window", iterations: 500) {
      let required = layout.keys(in: 10_000..<10_060)
      _ = TranscriptMountedWindowReadiness.resolvedKeys(required: required, measurements: ledger) { _ in true }
    }
    Self.measure("renderedWindow / contiguousRange (60 keys)", iterations: 500) {
      let keys = layout.keys(in: 10_000..<10_060)
      _ = layout.renderedWindow(covering: keys)
      _ = layout.contiguousRange(of: keys)
    }
    #expect(layout.keys.count == rows.count)
  }
}
