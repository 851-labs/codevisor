import ScreenSharingBench
import Testing

struct BenchUsageSummaryTests {
  @Test func onlySecondsInsideTheWindowCountAndTheSystemsProcessesAreSummedPerSecond() throws {
    let window = try #require(
      BenchSharingWindow(spans: [0...9_500_000_000], warmUpNs: 2_500_000_000, tailNs: 3_000_000_000))
    let seconds = (1...9).map { second in
      BenchUsageSecond(
        endNs: Int64(second) * 1_000_000_000, intervalNs: 1_000_000_000, receivedMbps: 8, sentMbps: 1,
        processes: [
          "a": .init(cpuPct: Double(second - 3) * 10, powerMw: 100), "b": .init(cpuPct: 5, powerMw: 50),
          "other": .init(cpuPct: 100, powerMw: 1_000),
        ])
    }

    let summary = BenchUsageSummary(seconds, in: window, processes: ["a", "b"])

    #expect(summary.cpuPct == BenchResult.ProcessUsage(p50: 25, p95: 35))
    #expect(summary.powerMw == 150)
    #expect(summary.receivedMbps == BenchResult.Bitrate(p50: 8, p95: 8, max: 8, totalMb: 3))
  }
}
