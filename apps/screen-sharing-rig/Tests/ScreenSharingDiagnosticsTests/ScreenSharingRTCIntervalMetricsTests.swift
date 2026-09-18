import Testing
import ScreenSharing
@testable import ScreenSharingDiagnostics

struct ScreenSharingRTCIntervalMetricsTests {
  private func sample(_ id: String = "a", seconds: String, count: String) -> [String: String] {
    ["inbound-rtp.\(id).jitterBufferDelay": seconds, "inbound-rtp.\(id).jitterBufferEmittedCount": count]
  }

  @Test func computesIntervalInsteadOfLifetimeMeanAndWeightsStreams() throws {
    var metrics = ScreenSharingRTCIntervalMetrics()
    let first = sample(seconds: "10", count: "100").merging(sample("b", seconds: "5", count: "100")) { a, _ in a }
    #expect(metrics.update(first).isEmpty)
    let next = sample(seconds: "10.5", count: "150").merging(sample("b", seconds: "9.5", count: "250")) { a, _ in a }
    #expect(try #require(metrics.update(next)["jitterBufferMeanMs"]) == 25)
    #expect(metrics.update(next).isEmpty)
  }

  @Test func rebaselinesResetMissingAndReplacedStreams() {
    var metrics = ScreenSharingRTCIntervalMetrics()
    _ = metrics.update(sample(seconds: "5", count: "100"))
    #expect(metrics.update(sample(seconds: "1", count: "10")).isEmpty)
    #expect(metrics.update(sample(seconds: "2", count: "20"))["jitterBufferMeanMs"] == 100)
    #expect(metrics.update([:]).isEmpty)
    #expect(metrics.update(sample(seconds: "3", count: "30")).isEmpty)
    #expect(metrics.update(sample("new", seconds: "4", count: "40")).isEmpty)
  }

  @Test(arguments: ["NaN", "inf", "-1", "invalid"])
  func rejectsInvalidTotalsAndRebaselines(_ invalid: String) {
    var metrics = ScreenSharingRTCIntervalMetrics()
    _ = metrics.update(sample(seconds: "1", count: "10"))
    #expect(metrics.update(sample(seconds: invalid, count: "20")).isEmpty)
    #expect(metrics.update(sample(seconds: "3", count: "30")).isEmpty)
    #expect(metrics.update(sample(seconds: "4", count: "40"))["jitterBufferMeanMs"] == 100)
  }
}
