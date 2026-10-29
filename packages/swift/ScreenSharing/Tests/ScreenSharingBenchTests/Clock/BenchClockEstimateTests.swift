import ScreenSharingBench
import Testing

struct BenchClockEstimateTests {
  private struct RemoteClock {
    let originNs: Int64 = 432_000_000_000_000
    let offsetNs: Int64 = -31_536_000_000_000 + 3_250_000
    let driftPpm = 2.0

    func remoteNs(atLocal localNs: Int64) -> Int64 {
      localNs + offsetNs + Int64((Double(localNs - originNs) * driftPpm / 1_000_000).rounded())
    }
  }

  @Test func theMinimumRoundTripProbesRecoverOffsetAndDriftWithinEpsilon() throws {
    let clock = RemoteClock()
    var random = SplitMix64(seed: 2)
    let bursts = (0..<300).map { burst in
      (0..<16).map { probe in
        exchange(sentAt: clock.originNs + Int64(burst) * 2_000_000_000 + Int64(probe) * 1_000_000, clock, &random)
      }
    }

    let estimate = try #require(BenchClockEstimate(bursts: bursts))

    #expect((0.4...0.5).contains(estimate.quality.epsilonMs))
    #expect(abs(estimate.quality.driftPpm - clock.driftPpm) < 0.05)
    #expect(estimate.quality.residualMs < 0.2)
    for elapsedNs: Int64 in [0, 300_000_000_000, 600_000_000_000] {
      let localNs = clock.originNs + elapsedNs
      let errorMs = Double(estimate.localNs(fromRemote: clock.remoteNs(atLocal: localNs)) - localNs) / 1_000_000
      #expect(abs(errorMs) <= estimate.quality.epsilonMs, "at +\(elapsedNs / 1_000_000_000) s")
    }
  }

  @Test func noProbesGiveNoEstimate() {
    #expect(BenchClockEstimate(bursts: []) == nil)
    #expect(BenchClockEstimate(bursts: [[], []]) == nil)
  }

  private func exchange(
    sentAt localSendNs: Int64, _ clock: RemoteClock, _ random: inout SplitMix64
  )
    -> BenchClockExchange
  {
    let forwardNs = 300_000 + jitterNs(&random) + queuedBehindTrafficNs(&random)
    let turnaroundNs: Int64 = 50_000
    let backwardNs = 500_000 + jitterNs(&random)
    return BenchClockExchange(
      localSendNs: localSendNs, remoteReceiveNs: clock.remoteNs(atLocal: localSendNs + forwardNs),
      remoteSendNs: clock.remoteNs(atLocal: localSendNs + forwardNs + turnaroundNs),
      localReceiveNs: localSendNs + forwardNs + turnaroundNs + backwardNs)
  }

  private func jitterNs(_ random: inout SplitMix64) -> Int64 {
    Int64(random.next() % 200_000)
  }

  private func queuedBehindTrafficNs(_ random: inout SplitMix64) -> Int64 {
    guard random.next() % 10 < 4 else { return 0 }

    return 2_000_000 + Int64(random.next() % 8_000_000)
  }
}
