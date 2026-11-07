import Testing

@testable import ScreenSharingV2

struct ScreenSharingV2EstimateTraceTests {
  @Test func eachClosedSecondRecordsItsLowestEstimate() {
    var trace = ScreenSharingV2EstimateTrace()
    let second: Int64 = 1_000_000_000

    let labels = [(60_000, 0), (45_500, second / 2), (70_000, second), (30_000, 2 * second)].map {
      trace.observe(estimateKbps: UInt64($0.0), atNs: $0.1)
    }

    #expect(labels == [nil, nil, "45.5", "45.5,70.0"])
  }

  @Test func secondsWithoutAnEstimateAreMarkedAsGaps() {
    var trace = ScreenSharingV2EstimateTrace()
    let second: Int64 = 1_000_000_000

    _ = trace.observe(estimateKbps: 50_000, atNs: 0)
    let label = trace.observe(estimateKbps: 40_000, atNs: 3 * second)

    #expect(label == "50.0,-,-")
  }
}
