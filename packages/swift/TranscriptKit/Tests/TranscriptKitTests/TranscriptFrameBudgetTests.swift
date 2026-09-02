import CoreGraphics
import Foundation
import Testing
@testable import TranscriptKit

struct TranscriptFrameBudgetTests {
  @Test func interactiveBudgetHalvesAboveSixtyHertz() {
    #expect(TranscriptFrameBudget(maximumFramesPerSecond: 60, isInteracting: true).mountsPerFrame == 4)
    #expect(TranscriptFrameBudget(maximumFramesPerSecond: 60, isInteracting: true).workBudget == 0.005)
    #expect(TranscriptFrameBudget(maximumFramesPerSecond: 120, isInteracting: true).mountsPerFrame == 2)
    #expect(TranscriptFrameBudget(maximumFramesPerSecond: 120, isInteracting: true).workBudget == 0.0025)
  }

  @Test func idleBudgetIsLarger() {
    #expect(TranscriptFrameBudget(maximumFramesPerSecond: 60, isInteracting: false).mountsPerFrame == 8)
    #expect(TranscriptFrameBudget(maximumFramesPerSecond: 60, isInteracting: false).workBudget == 0.008)
    #expect(TranscriptFrameBudget(maximumFramesPerSecond: 120, isInteracting: false).mountsPerFrame == 6)
    #expect(TranscriptFrameBudget(maximumFramesPerSecond: 120, isInteracting: false).workBudget == 0.004)
  }

  @Test func runwayPreparationsScaleWithProjectedMotion() {
    typealias B = TranscriptFrameBudget
    #expect(
      B.runwayPreparationsPerFrame(maximumFramesPerSecond: 60, projectedDistance: 0, viewportHeight: 800) == 2)
    #expect(
      B.runwayPreparationsPerFrame(maximumFramesPerSecond: 120, projectedDistance: 0, viewportHeight: 800) == 1)
    #expect(
      B.runwayPreparationsPerFrame(maximumFramesPerSecond: 60, projectedDistance: -300, viewportHeight: 800) == 3)
    #expect(
      B.runwayPreparationsPerFrame(maximumFramesPerSecond: 120, projectedDistance: 300, viewportHeight: 800) == 2)
    #expect(
      B.runwayPreparationsPerFrame(maximumFramesPerSecond: 60, projectedDistance: 800, viewportHeight: 800) == 4)
    #expect(
      B.runwayPreparationsPerFrame(maximumFramesPerSecond: 120, projectedDistance: 2400, viewportHeight: 800) == 3
    )
    // A degenerate viewport is clamped to 1pt, so any motion counts as a full viewport.
    #expect(B.runwayPreparationsPerFrame(maximumFramesPerSecond: 60, projectedDistance: 1, viewportHeight: 0) == 4)
  }
}

struct TranscriptPresentableRowHostTests {
  @MainActor
  private final class Host: TranscriptPresentableRowHost {
    var isPresentationReady: Bool
    var isAttachmentGeometryReady: Bool
    init(presentation: Bool, attachments: Bool) {
      isPresentationReady = presentation
      isAttachmentGeometryReady = attachments
    }
  }

  @Test @MainActor func promotionRequiresEveryCondition() {
    var ledger = TranscriptMeasurementLedger()
    ledger.setExact(10, for: "ok")
    ledger.setProvisional(10, for: "stale")
    let ready = Host(presentation: true, attachments: true)
    typealias R = TranscriptMountedWindowReadiness
    #expect(R.isPromotable(key: "ok", measurements: ledger, hasPendingMeasurement: false, host: ready))
    #expect(!R.isPromotable(key: "ok", measurements: ledger, hasPendingMeasurement: true, host: ready))
    #expect(!R.isPromotable(key: "stale", measurements: ledger, hasPendingMeasurement: false, host: ready))
    #expect(!R.isPromotable(key: "unmeasured", measurements: ledger, hasPendingMeasurement: false, host: ready))
    #expect(!R.isPromotable(key: "ok", measurements: ledger, hasPendingMeasurement: false, host: nil))
    #expect(
      !R.isPromotable(
        key: "ok", measurements: ledger, hasPendingMeasurement: false,
        host: Host(presentation: false, attachments: true)))
    #expect(
      !R.isPromotable(
        key: "ok", measurements: ledger, hasPendingMeasurement: false,
        host: Host(presentation: true, attachments: false)))
  }

  @Test @MainActor func resolvedKeysOverHostTable() {
    var ledger = TranscriptMeasurementLedger()
    ledger.setExact(10, for: "a")
    ledger.setExact(10, for: "b")
    ledger.setExact(10, for: "c")
    let hosts: [String: Host] = [
      "a": Host(presentation: true, attachments: true),
      "b": Host(presentation: false, attachments: true),
    ]
    let resolved = TranscriptMountedWindowReadiness.resolvedKeys(
      required: ["a", "b", "c"], measurements: ledger, hosts: hosts
    )
    #expect(resolved == ["a"])
  }
}
