import Testing
@testable import ScreenSharing

struct ScreenSharingFrameTimelineSummaryTests {
  @Test func eachStageSummarisesTheCompleteFramesInMilliseconds() throws {
    let records = (1...20).map { record(decodeUs: Int64($0) * 1_000, residualUs: 0) }
    let summary = try #require(ScreenSharingFrameTimelineSummary(records: records, unpresentedFrames: 3))

    let decode = try #require(summary.stages["decode"])
    #expect(decode.count == 20 && decode.p50Ms == 11 && decode.p95Ms == 20 && decode.maximumMs == 20)
    #expect(summary.stages["present"]?.p50Ms == 3)
    #expect(summary.frames == 20 && summary.incompleteFrames == 0 && summary.unpresentedFrames == 3)
    #expect(summary.version == ScreenSharingFrameTimelineSummary.formatVersion)
  }

  @Test func theResidualIsWhatTheStagesMissOfTheMeasuredLatency() throws {
    let records = [record(decodeUs: 2_000, residualUs: 500), record(decodeUs: 2_000, residualUs: -1_500)]
    let summary = try #require(ScreenSharingFrameTimelineSummary(records: records, unpresentedFrames: 0))

    #expect(summary.stageSum?.p50Ms == 10)
    #expect(summary.captureToPresent?.maximumMs == 10.5)
    #expect(summary.residual?.p50Ms == 0.5 && summary.residual?.maximumMs == 0.5)
  }

  @Test func incompleteFramesAreCountedButLeftOutOfTheStages() throws {
    let complete = record(decodeUs: 2_000, residualUs: 0)
    let incomplete = record(decodeUs: 9_000, residualUs: 0, network: false)
    let summary = try #require(
      ScreenSharingFrameTimelineSummary(records: [complete, incomplete], unpresentedFrames: 0))

    #expect(summary.frames == 1 && summary.incompleteFrames == 1)
    #expect(summary.stages["decode"]?.maximumMs == 2)
  }

  @Test func framesFromAnotherClockHaveNoMeasuredLatency() throws {
    let summary = try #require(
      ScreenSharingFrameTimelineSummary(records: [record(decodeUs: 2_000, residualUs: nil)], unpresentedFrames: 0))

    #expect(summary.stageSum?.p50Ms == 10)
    #expect(summary.captureToPresent == nil && summary.residual == nil)
  }

  @Test func noRecordsMeansNoSummary() {
    #expect(ScreenSharingFrameTimelineSummary(records: [], unpresentedFrames: 4) == nil)
  }

  private func record(decodeUs: Int64, residualUs: Int64?, network: Bool = true) -> ScreenSharingFrameRecord {
    let host = ScreenSharingHostFrameTiming(clock: 1, captureUs: 1_000, hostQueueUs: 1_000, encodeUs: 1_000)
    let decodedNs = decodeUs * 1_000
    let presentedNs = decodedNs + 3_000_000
    let stageSumUs = 3_000 + 2_000 + decodeUs + 3_000
    return ScreenSharingFrameRecord(
      sequence: 1,
      decoded: ScreenSharingDecodedFrameTiming(
        sourceTimestampNs: presentedNs - (stageSumUs + (residualUs ?? 0)) * 1_000, host: host, decodeInputNs: 0,
        decodeSubmitNs: 0, decodedNs: decodedNs, isKeyFrame: false),
      presentation: ScreenSharingFramePresentation(
        receivedAtNs: decodedNs, submittedAtNs: decodedNs, presentedAtNs: presentedNs),
      estimate: ScreenSharingOnGlassEstimate(displayLinkTargetNs: nil, replacesMissingPresentedTime: true),
      transport: network ? millisecondNetworkAndJitterBuffer() : ScreenSharingTransportEstimate(),
      localClock: residualUs == nil ? 2 : 1)
  }

  private func millisecondNetworkAndJitterBuffer() -> ScreenSharingTransportEstimate {
    var estimate = ScreenSharingTransportEstimate()
    for (delay, emitted) in [("0", "0"), ("0.001", "1")] {
      estimate.update(statistics: [
        "candidate-pair.CP1.currentRoundTripTime": "0.002",
        "inbound-rtp.IT1.jitterBufferDelay": delay,
        "inbound-rtp.IT1.jitterBufferEmittedCount": emitted,
      ])
    }
    return estimate
  }
}
