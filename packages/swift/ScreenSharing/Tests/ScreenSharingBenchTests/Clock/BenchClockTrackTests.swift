import Foundation
import ScreenSharingBench
import Testing

struct BenchClockTrackTests {
  private struct WanderingClock {
    let originNs: Int64 = 86_400_000_000_000
    let offsetNs: Int64 = 12_035_000_000
    let wanderAmplitudeNs = 800_000.0
    let wanderPeriodNs = 500_000_000_000.0

    func remoteNs(atLocal localNs: Int64) -> Int64 {
      let phase = 2 * Double.pi * Double(localNs - originNs) / wanderPeriodNs
      return localNs + offsetNs + Int64((wanderAmplitudeNs * sin(phase)).rounded())
    }
  }

  @Test func aWindowedFitFollowsARateThatWandersWhereOneLineCannot() throws {
    let clock = WanderingClock()
    var random = SplitMix64(seed: 3)
    let bursts = (0..<300).map { burst in
      (0..<16).map { probe in
        exchange(sentAt: clock.originNs + Int64(burst) * 2_000_000_000 + Int64(probe) * 1_000_000, clock, &random)
      }
    }

    let track = try #require(BenchClockTrack(bursts: bursts))

    #expect(track.linearResidualMs > 0.5)
    #expect(track.quality.residualMs < 0.2)
    for elapsedNs: Int64 in [1_000_000_000, 125_000_000_000, 300_000_000_000, 599_000_000_000] {
      let localNs = clock.originNs + elapsedNs
      let errorMs = Double(track.localNs(fromRemote: clock.remoteNs(atLocal: localNs)) - localNs) / 1_000_000
      #expect(abs(errorMs) <= track.quality.epsilonMs, "at +\(elapsedNs / 1_000_000_000) s")
    }
  }

  @Test func oneBurstIsNotATrack() {
    let exchange = BenchClockExchange(localSendNs: 0, remoteReceiveNs: 10, remoteSendNs: 20, localReceiveNs: 30)

    #expect(BenchClockTrack(bursts: [[exchange], []]) == nil)
  }

  private func exchange(
    sentAt localSendNs: Int64, _ clock: WanderingClock, _ random: inout SplitMix64
  )
    -> BenchClockExchange
  {
    let forwardNs = 250_000 + Int64(random.next() % 300_000)
    let turnaroundNs: Int64 = 40_000
    let backwardNs = 350_000 + Int64(random.next() % 300_000)
    return BenchClockExchange(
      localSendNs: localSendNs, remoteReceiveNs: clock.remoteNs(atLocal: localSendNs + forwardNs),
      remoteSendNs: clock.remoteNs(atLocal: localSendNs + forwardNs + turnaroundNs),
      localReceiveNs: localSendNs + forwardNs + turnaroundNs + backwardNs)
  }
}
