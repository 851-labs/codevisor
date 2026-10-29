import ScreenSharingBench
import Testing

struct BenchRelayLinkTests {
  @Test func packetsLeaveInOrderOnceTheirDelayHasPassed() {
    var link = BenchRelayLink<Int>(conditions: .n1, seed: 1, originNs: 0)
    let delayNs: Int64 = 1_000_000
    let serializationNs: Int64 = 1_000 * 8 * 1_000_000 / 1_000_000

    link.offer(1, byteCount: 1_000, atNs: 0)
    link.offer(2, byteCount: 1_000, atNs: 0)

    #expect(link.nextDueNs == delayNs + serializationNs)
    #expect(link.takeDue(atNs: delayNs + serializationNs - 1).isEmpty)
    #expect(link.takeDue(atNs: delayNs + serializationNs) == [1])
    #expect(link.takeDue(atNs: delayNs + 2 * serializationNs) == [2])
    #expect(link.nextDueNs == nil)
  }

  @Test func theSameSeedLosesTheSamePacketsAndTheReportNamesThem() {
    let losses = { (seed: UInt64) in
      var link = BenchRelayLink<Int>(conditions: .n3, seed: seed, originNs: 0)
      for index in 0..<2_000 { link.offer(index, byteCount: 1_200, atNs: Int64(index) * 100_000) }
      return link.statistics
    }

    let first = losses(7)
    let delivered = 2_000 - first.lost
    #expect(first == losses(7))
    #expect(first.firstLosses != losses(8).firstLosses)
    #expect(first.packets == 2_000 && first.bytes == 2_400_000)
    #expect((10...30).contains(first.lost), "1% of 2,000 packets")
    #expect(first.firstLosses.count == min(first.lost, BenchRelayStatistics.firstLossesKept))
    #expect(delivered > 0)
  }

  @Test func queueOverflowsAreCountedApartFromTheSeededLosses() {
    var link = BenchRelayLink<Int>(conditions: .n5, seed: 7, originNs: 0)
    for index in 0..<40 { link.offer(index, byteCount: 1_250, atNs: 0) }

    #expect(link.statistics.queueOverflow == 10)
    #expect(link.statistics.lost == 0 && link.statistics.firstLosses.isEmpty)
  }

  @Test func bitrateCountsOfferedBytesPerSecondAfterTheOrigin() throws {
    var link = BenchRelayLink<Int>(conditions: .n0, seed: 1, originNs: 10_000_000_000)
    link.offer(0, byteCount: 1_000_000, atNs: 9_000_000_000)
    link.offer(1, byteCount: 1_000_000, atNs: 10_500_000_000)
    link.offer(2, byteCount: 2_000_000, atNs: 11_200_000_000)
    link.offer(3, byteCount: 1_000_000, atNs: 11_900_000_000)

    let bitrate = try #require(link.traffic.bitrate(fromSecond: 0, toSecond: 3))

    #expect(bitrate == BenchResult.Bitrate(p50: 8, p95: 24, max: 24, totalMb: 4))
    #expect(link.traffic.bitrate(fromSecond: 1, toSecond: 2)?.p50 == 24)
    #expect(link.traffic.bitrate(fromSecond: 3, toSecond: 3) == nil)
  }
}
