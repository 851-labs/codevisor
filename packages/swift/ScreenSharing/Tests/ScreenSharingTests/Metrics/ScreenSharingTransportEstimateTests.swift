import Testing
@testable import ScreenSharing

struct ScreenSharingTransportEstimateTests {
  @Test func networkTimeIsHalfTheRoundTrip() {
    var estimate = ScreenSharingTransportEstimate()
    estimate.update(statistics: ["candidate-pair.CP1.currentRoundTripTime": "0.0125"])
    #expect(estimate.networkUs == 6_250)
  }

  @Test func theJitterBufferIsTheMeanDelayOfTheFramesEmittedSinceTheLastSample() {
    var estimate = ScreenSharingTransportEstimate()
    estimate.update(statistics: jitter(delay: 10, emitted: 1_000))
    #expect(estimate.jitterBufferUs == nil, "one sample has no interval yet")

    estimate.update(statistics: jitter(delay: 11.2, emitted: 1_060))
    #expect(estimate.jitterBufferUs == 20_000)

    estimate.update(statistics: jitter(delay: 11.2, emitted: 1_060))
    #expect(estimate.jitterBufferUs == 20_000, "an interval without frames keeps the last estimate")
  }

  @Test func missingStatisticsLeaveTheEstimateUnchanged() {
    var estimate = ScreenSharingTransportEstimate()
    estimate.update(statistics: ["candidate-pair.CP1.currentRoundTripTime": "0.002"])
    estimate.update(statistics: ["inbound-rtp.IT1.framesDecoded": "4"])
    #expect(estimate.networkUs == 1_000 && estimate.jitterBufferUs == nil)
  }

  @Test func bothJitterCountersComeFromTheBusiestInboundStream() {
    var estimate = ScreenSharingTransportEstimate()
    for (busy, stale) in [((10.0, 1_000), (9.0, 3)), ((11.2, 1_060), (9.0, 3))] {
      estimate.update(
        statistics: jitter(delay: busy.0, emitted: busy.1, stream: "IT1")
          .merging(jitter(delay: stale.0, emitted: stale.1, stream: "IT0")) { first, _ in first })
    }
    #expect(estimate.jitterBufferUs == 20_000)
  }

  private func jitter(delay: Double, emitted: Int, stream: String = "IT1") -> [String: String] {
    [
      "inbound-rtp.\(stream).jitterBufferDelay": String(delay),
      "inbound-rtp.\(stream).jitterBufferEmittedCount": String(emitted),
    ]
  }
}
