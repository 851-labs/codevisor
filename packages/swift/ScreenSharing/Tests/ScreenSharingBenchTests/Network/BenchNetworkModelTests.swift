import ScreenSharingBench
import Testing

struct BenchNetworkModelTests {
  @Test func theSameSeedGivesTheSameFates() {
    let fates = { (seed: UInt64) in
      var model = BenchNetworkModel(conditions: .n6, seed: seed)
      return (0..<5_000).map { model.send(byteCount: 1_200, atNs: Int64($0) * 1_000_000) }
    }

    #expect(fates(7) == fates(7))
    #expect(fates(7) != fates(8))
  }

  @Test(arguments: [
    (conditions: BenchNetworkConditions.n3, meanBurst: 1.0),
    (conditions: BenchNetworkConditions.n4, meanBurst: 5.0),
  ])
  func lossMatchesTheConfiguredRateAndMeanBurstLength(conditions: BenchNetworkConditions, meanBurst: Double) {
    var loss = BenchLossModel(
      lossPercent: conditions.lossPercent, averageBurstLength: conditions.averageBurstLossLength, seed: 11)
    let drops = (0..<1_000_000).map { _ in loss.dropsNextPacket() }

    let bursts = lossBurstLengths(drops)
    let lossPercent = Double(drops.count { $0 }) / Double(drops.count) * 100
    let observedMeanBurst = Double(bursts.reduce(0, +)) / Double(bursts.count)
    #expect(abs(lossPercent - conditions.lossPercent) < 0.1)
    #expect(abs(observedMeanBurst - meanBurst) < meanBurst * 0.05)
  }

  @Test func aFullQueueDropsPacketsUntilTheLinkDrainsIt() {
    var model = BenchNetworkModel(conditions: .n5, seed: 1)
    let serializationNs: Int64 = 1_250 * 8 * 1_000_000 / 30_000

    let burst = (0..<40).map { _ in model.send(byteCount: 1_250, atNs: 0) }
    let afterDrain = model.send(byteCount: 1_250, atNs: 30 * serializationNs)

    let queued: [BenchPacketFate] = (1...30).map { .delivered(atNs: Int64($0) * serializationNs + 10_000_000) }
    #expect(Array(burst.prefix(30)) == queued)
    #expect(burst.dropFirst(30).allSatisfy { $0 == .queueOverflow })
    #expect(afterDrain == .delivered(atNs: 31 * serializationNs + 10_000_000))
  }

  @Test func jitterNeverReordersPackets() {
    var model = BenchNetworkModel(
      conditions: BenchNetworkConditions(id: "jittery", delayMs: 5, delayStandardDeviationMs: 20), seed: 3)

    let sentNs = (0..<2_000).map { Int64($0) * 1_000_000 }
    let arrivals = sentNs.compactMap { sent -> Int64? in
      guard case .delivered(let atNs) = model.send(byteCount: 1_200, atNs: sent) else { return nil }
      return atNs
    }

    let delaysNs = zip(arrivals, sentNs).map { $0 - $1 }
    #expect(arrivals.count == sentNs.count)
    #expect(zip(arrivals, arrivals.dropFirst()).allSatisfy { $0 <= $1 })
    #expect(Set(delaysNs).count > 100)
  }

  private func lossBurstLengths(_ drops: [Bool]) -> [Int] {
    var bursts: [Int] = []
    var current = 0
    for dropped in drops {
      if dropped {
        current += 1
      } else if current > 0 {
        bursts.append(current)
        current = 0
      }
    }
    return bursts
  }
}
