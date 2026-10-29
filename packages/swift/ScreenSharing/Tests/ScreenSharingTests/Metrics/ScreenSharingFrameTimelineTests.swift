import Foundation
import Testing
@testable import ScreenSharing

struct ScreenSharingFrameTimelineTests {
  private let clock: UInt64 = 7
  private let sourceNs: Int64 = 1_000_000_000

  @Test func onOneClockTheStagesAddUpToCaptureToPresent() throws {
    let timeline = ScreenSharingFrameTimeline(localClock: clock)
    observeTransport(timeline, roundTripSeconds: 0.004, jitterBufferDelaySeconds: 0.5, emitted: 100)
    timeline.decoded(decodedFrame(sourceNs, hostClock: clock, decodeStartMs: 15, decodedMs: 18))
    timeline.presented(sourceTimestampNs: sourceNs, presentation(receivedMs: 19, submittedMs: 23, presentedMs: 40))

    let record = try #require(timeline.records(after: 0).first)
    var expected = ScreenSharingFrameStages()
    expected.capture = 1_000
    expected.hostQueue = 2_000
    expected.encode = 5_000
    expected.network = 2_000
    expected.jitterBuffer = 5_000
    expected.decode = 3_000
    expected.delivery = 1_000
    expected.renderQueue = 4_000
    expected.present = 17_000
    #expect(record.stagesUs == expected)
    #expect(record.sameClock && record.stageSumUs == 40_000 && record.captureToPresentUs == 40_000)
  }

  @Test func aHostOnAnotherClockGetsNoCaptureToPresent() throws {
    let timeline = ScreenSharingFrameTimeline(localClock: clock)
    timeline.decoded(decodedFrame(sourceNs, hostClock: clock + 1, decodeStartMs: 15, decodedMs: 18))
    timeline.presented(sourceTimestampNs: sourceNs, presentation(receivedMs: 19, submittedMs: 23, presentedMs: 40))

    let record = try #require(timeline.records(after: 0).first)
    #expect(!record.sameClock && record.captureToPresentUs == nil)
    #expect(record.stagesUs.network == nil && record.stageSumUs == nil, "no RTT has been observed yet")
  }

  @Test func anUnknownClockIsNeverTheSameClock() throws {
    let timeline = ScreenSharingFrameTimeline(localClock: 0)
    timeline.decoded(decodedFrame(sourceNs, hostClock: 0, decodeStartMs: 15, decodedMs: 18))
    timeline.presented(sourceTimestampNs: sourceNs, presentation(receivedMs: 19, submittedMs: 23, presentedMs: 40))

    #expect(try #require(timeline.records(after: 0).first).sameClock == false)
  }

  @Test func aPresentationIsRecordedOnceAndOnlyForADecodedFrame() {
    let timeline = ScreenSharingFrameTimeline(localClock: clock)
    timeline.presented(sourceTimestampNs: sourceNs, presentation(receivedMs: 19, submittedMs: 23, presentedMs: 40))
    timeline.decoded(decodedFrame(sourceNs, hostClock: clock, decodeStartMs: 15, decodedMs: 18))
    timeline.presented(sourceTimestampNs: sourceNs, presentation(receivedMs: 19, submittedMs: 23, presentedMs: 40))
    timeline.presented(sourceTimestampNs: sourceNs, presentation(receivedMs: 19, submittedMs: 23, presentedMs: 60))

    #expect(timeline.records(after: 0).map(\.viewer.onGlassNs) == [sourceNs + 40_000_000])
  }

  @Test func aRefreshedIdentityIsMatchedToItsNewestDecode() throws {
    let timeline = ScreenSharingFrameTimeline(localClock: clock)
    timeline.decoded(decodedFrame(sourceNs, hostClock: clock, decodeStartMs: 15, decodedMs: 18))
    timeline.decoded(decodedFrame(sourceNs, hostClock: clock, decodeStartMs: 30, decodedMs: 31))
    timeline.presented(sourceTimestampNs: sourceNs, presentation(receivedMs: 32, submittedMs: 33, presentedMs: 40))

    #expect(try #require(timeline.records(after: 0).first).stagesUs.decode == 1_000)
  }

  @Test func decodedFramesThatAreNeverPresentedAreCountedWhenEvicted() {
    let timeline = ScreenSharingFrameTimeline(localClock: clock)
    for index in 0..<20 {
      timeline.decoded(decodedFrame(Int64(index), hostClock: clock, decodeStartMs: 1, decodedMs: 2))
    }
    for index in 0..<20 {
      timeline.presented(sourceTimestampNs: Int64(index), presentation(receivedMs: 3, submittedMs: 4, presentedMs: 5))
    }

    #expect(timeline.records(after: 0).map(\.sourceTimestampNs) == Array(4..<20).map(Int64.init))
    #expect(timeline.summary()?.unpresentedFrames == 4)
  }

  @Test func recordsAfterASequenceAreTheNewestInOrderAndBounded() {
    let timeline = ScreenSharingFrameTimeline(localClock: clock)
    let total = ScreenSharingFrameTimeline.recordCapacity + 5
    for index in 0..<total {
      timeline.decoded(decodedFrame(Int64(index), hostClock: clock, decodeStartMs: 1, decodedMs: 2))
      timeline.presented(sourceTimestampNs: Int64(index), presentation(receivedMs: 3, submittedMs: 4, presentedMs: 5))
    }

    let all = timeline.records(after: 0)
    #expect(all.count == ScreenSharingFrameTimeline.recordCapacity)
    #expect(all.first?.sequence == 6 && all.last?.sequence == UInt64(total))
    #expect(timeline.records(after: UInt64(total - 2)).map(\.sequence) == [UInt64(total - 1), UInt64(total)])
  }

  @Test func theRecordEncodesStagesInMicrosecondsAndOmitsUnmeasuredOnes() throws {
    let timeline = ScreenSharingFrameTimeline(localClock: clock)
    timeline.decoded(decodedFrame(sourceNs, hostClock: clock, decodeStartMs: 15, decodedMs: 18))
    timeline.presented(sourceTimestampNs: sourceNs, presentation(receivedMs: 19, submittedMs: 23, presentedMs: 40))

    let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(timeline.records(after: 0)[0]))
    let record = try #require(json as? [String: Any])
    let stages = try #require(record["stagesUs"] as? [String: Int])
    #expect(
      stages == [
        "capture": 1000, "hostQueue": 2000, "encode": 5000, "decode": 3000, "delivery": 1000,
        "renderQueue": 4000, "present": 17000,
      ])
    #expect(record["captureToPresentUs"] as? Int == 40_000 && record["stageSumUs"] == nil)
    let host = try #require(record["host"] as? [String: Int])
    #expect(host["captureCallbackNs"] == Int(sourceNs) + 1_000_000)
    #expect(host["encodeOutputNs"] == Int(sourceNs) + 8_000_000)
    let viewer = try #require(record["viewer"] as? [String: Any])
    #expect(viewer["onGlassSource"] as? String == "presentedTime")
    #expect(viewer["mailboxPutNs"] as? Int == Int(sourceNs) + 19_000_000)
  }

  @Test func withoutAPresentedTimeTheFrameIsOnGlassOneRefreshAfterTheGPUIsReady() throws {
    let timeline = ScreenSharingFrameTimeline(localClock: clock)
    timeline.observeRefresh(targetNs: sourceNs + 30_000_000, periodNs: 16_000_000)
    timeline.decoded(decodedFrame(sourceNs, hostClock: clock, decodeStartMs: 15, decodedMs: 18))
    timeline.presented(
      sourceTimestampNs: sourceNs,
      ScreenSharingFramePresentation(receivedAt: 1.019, submittedAt: 1.023, gpuCompletedAt: 1.047, presentedAt: 0))

    let record = try #require(timeline.records(after: 0).first)
    #expect(record.viewer.gpuCompletedNs == sourceNs + 47_000_000)
    #expect(record.viewer.onGlassNs == sourceNs + 78_000_000 && record.viewer.onGlassSource == .displayLinkTarget)
    #expect(record.stagesUs.present == 55_000 && record.captureToPresentUs == 78_000)
  }

  @Test func onceDrawablesReportPresentedTimesAMissingOneMeansTheFrameNeverReachedTheGlass() throws {
    let timeline = ScreenSharingFrameTimeline(localClock: clock)
    timeline.observeRefresh(targetNs: sourceNs + 30_000_000, periodNs: 16_000_000)
    timeline.decoded(decodedFrame(sourceNs, hostClock: clock, decodeStartMs: 15, decodedMs: 18))
    timeline.presented(sourceTimestampNs: sourceNs, presentation(receivedMs: 19, submittedMs: 23, presentedMs: 40))
    timeline.decoded(decodedFrame(sourceNs + 1, hostClock: clock, decodeStartMs: 31, decodedMs: 33))
    timeline.presented(
      sourceTimestampNs: sourceNs + 1,
      ScreenSharingFramePresentation(receivedAt: 1.034, submittedAt: 1.036, gpuCompletedAt: 1.047, presentedAt: 0))

    let dropped = try #require(timeline.records(after: 1).first)
    #expect(dropped.viewer.displayLinkTargetNs == sourceNs + 78_000_000)
    #expect(dropped.viewer.onGlassNs == nil && dropped.stagesUs.present == nil)
  }

  @Test func withoutAnyOnGlassTimeThePresentStageIsMissing() throws {
    let timeline = ScreenSharingFrameTimeline(localClock: clock)
    timeline.decoded(decodedFrame(sourceNs, hostClock: clock, decodeStartMs: 15, decodedMs: 18))
    timeline.presented(
      sourceTimestampNs: sourceNs,
      ScreenSharingFramePresentation(receivedAt: 1.019, submittedAt: 1.023, presentedAt: 0))

    let record = try #require(timeline.records(after: 0).first)
    #expect(record.viewer.onGlassNs == nil && record.viewer.onGlassSource == nil)
    #expect(record.stagesUs.present == nil && record.captureToPresentUs == nil)
  }

  private func decodedFrame(
    _ source: Int64, hostClock: UInt64, decodeStartMs: Int64, decodedMs: Int64
  ) -> ScreenSharingDecodedFrameTiming {
    ScreenSharingDecodedFrameTiming(
      sourceTimestampNs: source,
      host: ScreenSharingHostFrameTiming(clock: hostClock, captureUs: 1_000, hostQueueUs: 2_000, encodeUs: 5_000),
      decodeInputNs: sourceNs + decodeStartMs * 1_000_000, decodeSubmitNs: sourceNs + decodeStartMs * 1_000_000,
      decodedNs: sourceNs + decodedMs * 1_000_000, isKeyFrame: false)
  }

  private func presentation(
    receivedMs: Int64, submittedMs: Int64, presentedMs: Int64
  )
    -> ScreenSharingFramePresentation
  {
    ScreenSharingFramePresentation(
      receivedAtNs: sourceNs + receivedMs * 1_000_000, submittedAtNs: sourceNs + submittedMs * 1_000_000,
      presentedAtNs: sourceNs + presentedMs * 1_000_000)
  }

  private func observeTransport(
    _ timeline: ScreenSharingFrameTimeline, roundTripSeconds: Double, jitterBufferDelaySeconds: Double, emitted: Int
  ) {
    timeline.observeTransport(transportStatistics(roundTripSeconds: roundTripSeconds, delay: 0, emitted: 0))
    timeline.observeTransport(
      transportStatistics(roundTripSeconds: roundTripSeconds, delay: jitterBufferDelaySeconds, emitted: emitted))
  }

  private func transportStatistics(roundTripSeconds: Double, delay: Double, emitted: Int) -> [String: String] {
    [
      "candidate-pair.CP1.currentRoundTripTime": String(roundTripSeconds),
      "inbound-rtp.IT1.jitterBufferDelay": String(delay),
      "inbound-rtp.IT1.jitterBufferEmittedCount": String(emitted),
    ]
  }
}
