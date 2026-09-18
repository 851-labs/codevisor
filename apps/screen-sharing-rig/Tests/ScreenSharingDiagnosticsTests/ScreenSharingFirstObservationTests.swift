import Testing

import ScreenSharing
@testable import ScreenSharingDiagnostics

@Suite struct ScreenSharingFirstObservationTests {
  @Test func firstNonZeroTickIsRecordedOncePerMetricWithInitialAndFinalValues() {
    var observation = ScreenSharingFirstObservation(names: [
      "anyCallback", "completeStatus", "capturedFrames", "decodedFrames",
    ])
    #expect(observation.record(elapsedSeconds: 0, values: [:]) == [])
    #expect(observation.record(elapsedSeconds: 1.02, values: ["anyCallback": 3]) == ["anyCallback"])
    // A complete status alone is not an accepted frame: capturedFrames stays unobserved.
    #expect(
      observation.record(elapsedSeconds: 2.05, values: ["anyCallback": 60, "completeStatus": 57]) == ["completeStatus"])
    #expect(
      observation.record(
        elapsedSeconds: 3.1,
        values: ["anyCallback": 120, "completeStatus": 117, "capturedFrames": 110, "decodedFrames": 100]) == [
          "capturedFrames", "decodedFrames",
        ])
    #expect(
      observation.record(
        elapsedSeconds: 4.1,
        values: ["anyCallback": 180, "completeStatus": 177, "capturedFrames": 170, "decodedFrames": 160]) == [])
    let any = observation.metrics["anyCallback"]!
    #expect(
      any.initialValue == 0 && any.finalValue == 180 && any.firstObservedTick == 1 && any.firstObservedAtSeconds == 1.02
        && any.valueWhenFirstObserved == 3)
    #expect(observation.metrics["capturedFrames"]?.firstObservedTick == 3)
    #expect(observation.ticks == 5)
    let summary = observation.summary
    #expect(summary["completeStatus"]?["firstObservedAtSeconds"] == "2.05")
    #expect(summary["capturedFrames"]?["resolution"] == ScreenSharingFirstObservation.resolution)
  }

  @Test func neverObservedStaysExplicitAndCountersAreNotAccumulated() {
    var observation = ScreenSharingFirstObservation(names: ["anyCallback", "capturedFrames"])
    for tick in 0..<5 {
      observation.record(elapsedSeconds: Double(tick), values: ["anyCallback": 0, "capturedFrames": 0])
    }
    let summary = observation.summary
    #expect(summary["anyCallback"]?["firstObservedAtSeconds"] == "never observed")
    #expect(summary["anyCallback"]?["firstObservedTick"] == "never observed")
    #expect(summary["capturedFrames"]?["initialValue"] == "0" && summary["capturedFrames"]?["finalValue"] == "0")
    #expect(observation.metrics.count == 2)  // bounded: one entry per metric, no per-tick history
    var unrecorded = ScreenSharingFirstObservation(names: ["x"])
    #expect(unrecorded.summary["x"]?["initialValue"] == "not recorded")
    unrecorded.record(elapsedSeconds: 0, values: [:])
    #expect(unrecorded.summary["x"]?["initialValue"] == "0")
  }
}

@Suite struct ScreenSharingOwnedWindowGeometryTests {
  typealias Geometry = ScreenSharingOwnedWindowGeometry

  @Test func cocoaFrameConvertsToTopLeftUsingTheMainDisplayHeight() {
    // The run's window: Cocoa (0, 540, 960, 540) on a 1080-point main display → top-left (0, 0, 960, 540).
    let frame = Geometry.Rect(x: 0, y: 540, width: 960, height: 540)
    #expect(
      Geometry.cocoaToTopLeft(frame, mainDisplayHeight: 1080) == Geometry.Rect(x: 0, y: 0, width: 960, height: 540))
    // A different main display height gives a different answer: the conversion is only valid with the real height.
    #expect(
      Geometry.cocoaToTopLeft(frame, mainDisplayHeight: 900) == Geometry.Rect(x: 0, y: -180, width: 960, height: 540))
  }

  @Test func ownWindowRecordRequiresTheExactNumberAndPidAndKeepsEveryOtherStateExplicit() {
    let mine = Geometry.WindowListEntry(
      number: 12829, ownerPID: 55188, bounds: Geometry.Rect(x: 8, y: 4, width: 944, height: 532), layer: 0,
      isOnscreen: true, alpha: 1)
    let other = Geometry.WindowListEntry(
      number: 12272, ownerPID: 1, bounds: nil, layer: nil, isOnscreen: nil, alpha: nil)
    let unreported = Geometry.WindowListEntry(
      number: 12829, ownerPID: nil, bounds: Geometry.Rect(x: 1, y: 1, width: 2, height: 2), layer: 0, isOnscreen: true,
      alpha: 1)
    #expect(Geometry.ownWindow(in: [other, mine], number: 12829, pid: 55188) == .found(mine))
    #expect(Geometry.ownWindow(in: [other], number: 12829, pid: 55188) == .absent)
    #expect(Geometry.ownWindow(in: nil, number: 12829, pid: 55188) == .queryUnavailable)
    // Exact ID with an unreported owner: not "absent", and its fields are not persisted.
    #expect(Geometry.ownWindow(in: [other, unreported], number: 12829, pid: 55188) == .ownerUnreported)
    #expect(Geometry.ownWindow(in: [other, mine], number: 12829, pid: 1) == .ownerMismatch(reportedPID: 55188))
    #expect(Geometry.ownWindow(in: [mine, mine], number: 12829, pid: 55188) == .duplicate(count: 2))
  }
}

@Suite struct ScreenSharingCallbackTotalTests {
  @Test func completeSampleWithoutImageCountsOnceNotTwice() {
    typealias A = ScreenSharingCaptureCallbackAccounting
    // A valid complete sample without an image increments BOTH complete and missingImage.
    let metrics = ScreenSharingMetrics()
    A.record(valid: true, rawStatus: 0, hasImage: false, metrics: metrics)
    #expect(A.callbackTotal(counters: metrics.snapshot().counters) == 1)
    A.record(valid: true, rawStatus: 0, hasImage: true, metrics: metrics)  // complete with image
    A.record(valid: true, rawStatus: 1, hasImage: true, metrics: metrics)  // idle
    A.record(valid: false, rawStatus: 0, hasImage: true, metrics: metrics)  // invalid
    A.record(valid: true, rawStatus: nil, hasImage: true, metrics: metrics)  // missing status
    A.record(valid: true, rawStatus: 42, hasImage: true, metrics: metrics)  // other status
    let counters = metrics.snapshot().counters
    #expect(counters["captureSamplesWithoutImage"] == 1 && counters["captureCallbacksComplete"] == 2)
    #expect(A.callbackTotal(counters: counters) == 6)
  }
}
