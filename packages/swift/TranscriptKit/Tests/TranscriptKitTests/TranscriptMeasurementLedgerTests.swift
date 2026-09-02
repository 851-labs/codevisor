import CoreGraphics
import Testing
@testable import TranscriptKit

struct TranscriptMeasurementLedgerTests {
  @Test func revisionChangePreservesMeasuredHeightForLayout() {
    var ledger = TranscriptMeasurementLedger()
    ledger.commit(1_240, for: "message:a")

    // A background subagent flushed into the settled row: its revision
    // moved, so the measurement is stale — but layout must keep using the
    // real height, never revert to the row's flat estimate.
    ledger.markStale("message:a")

    let layout = VirtualTranscriptLayout(
      items: [
        .init(key: "message:a", estimatedHeight: 320),
        .init(key: "message:b", estimatedHeight: 44),
      ],
      measuredHeights: ledger.heightsByKey,
      spacing: 20
    )
    #expect(layout.heights == [1_240, 44])
    #expect(layout.topOffsets == [0, 1_260])
  }

  @Test func staleKeyCommitsUnchangedHeightAndSettles() {
    var ledger = TranscriptMeasurementLedger()
    ledger.commit(500, for: "message:a")
    ledger.markStale("message:a")

    // The remeasure landed on the same height. It must still commit (so
    // revision-keyed caches relearn the row) — but must not report a
    // geometry change, and afterwards the ordinary dedupe applies again.
    #expect(ledger.needsCommit(500, for: "message:a"))
    let geometryChanged = ledger.commit(500, for: "message:a")
    #expect(geometryChanged == false)
    #expect(ledger.isStale("message:a") == false)
    #expect(ledger.needsCommit(500, for: "message:a") == false)
  }

  @Test func currentKeyDedupesUnchangedHeights() {
    var ledger = TranscriptMeasurementLedger()
    ledger.commit(500, for: "message:a")

    #expect(ledger.needsCommit(500, for: "message:a") == false)
    #expect(ledger.needsCommit(500.4, for: "message:a") == false)
    #expect(ledger.needsCommit(501, for: "message:a"))
    let geometryChanged = ledger.commit(501, for: "message:a")
    #expect(geometryChanged)
  }

  @Test func firstMeasurementAlwaysCommits() {
    let ledger = TranscriptMeasurementLedger()
    #expect(ledger["message:a"] == nil)
    #expect(ledger.needsCommit(1, for: "message:a"))
  }

  @Test func provisionalHeightIsUsedButRequiresRecommit() {
    var ledger = TranscriptMeasurementLedger()
    // The active row's streaming height transferred onto the newly
    // settled row: good enough to position rows, not authoritative.
    ledger.setProvisional(880, for: "message:a")

    #expect(ledger["message:a"] == 880)
    #expect(ledger.isStale("message:a"))
    #expect(ledger.needsCommit(880, for: "message:a"))
  }

  @Test func exactHeightNeedsNoRecommit() {
    var ledger = TranscriptMeasurementLedger()
    ledger.setExact(64, for: "special:bottom-spacer")
    #expect(ledger.isStale("special:bottom-spacer") == false)
    #expect(ledger.needsCommit(64, for: "special:bottom-spacer") == false)
  }

  @Test func markStaleWithoutHeightIsInert() {
    var ledger = TranscriptMeasurementLedger()
    ledger.markStale("message:a")
    #expect(ledger.isStale("message:a") == false)
    #expect(ledger["message:a"] == nil)
  }

  @Test func removeAllClearsHeightsAndStaleness() {
    var ledger = TranscriptMeasurementLedger()
    ledger.commit(500, for: "message:a")
    ledger.markStale("message:a")
    ledger.removeAll(keepingCapacity: true)

    #expect(ledger["message:a"] == nil)
    #expect(ledger.isStale("message:a") == false)
    #expect(ledger.heightsByKey.isEmpty)
  }
}
