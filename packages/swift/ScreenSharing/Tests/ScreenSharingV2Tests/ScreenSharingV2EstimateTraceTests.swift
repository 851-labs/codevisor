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
}
