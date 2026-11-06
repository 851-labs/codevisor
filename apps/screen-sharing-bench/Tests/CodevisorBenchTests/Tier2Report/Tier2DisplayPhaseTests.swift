import ScreenSharingBench
import Testing

@testable import CodevisorBench

struct Tier2DisplayPhaseTests {
  private static let originNs: Int64 = 86_400_000_000_000
  private static let refreshNs = 1_000_000_000.0 / 60

  @Test(arguments: [9.8, 13.6, 0.4])
  func thePhaseIsTheViewerRefreshMinusTheHostRefreshOnTheViewersClock(phaseMs: Double) throws {
    let hostAheadNs = 100_000_000_000 + Int64(phaseMs * 1_000_000)
    let clock = try #require(BenchClockTrack(bursts: Self.bursts(hostAheadNs: hostAheadNs)))
    let host = Self.frames(startingAt: Self.originNs + hostAheadNs)
    let viewer = Self.frames(startingAt: Self.originNs)

    let phase = try #require(Tier2DisplayPhase.ms(host: host, viewer: viewer, clock: clock))

    #expect(abs(phase - phaseMs) < 0.01)
  }

  @Test func framesWithNoSteadyRefreshHaveNoPhase() {
    let times = (0..<600).map { Self.originNs + Int64($0) * 11_000_000 }

    #expect(Tier2DisplayPhase.meanPhaseNs(times) == nil)
  }

  private static func frames(startingAt startNs: Int64) -> [BenchObservation] {
    let firstRefresh = Int64((Double(startNs) / refreshNs).rounded(.up))
    return (0..<1_200).map { frame in
      let ptsNs = Int64((Double(firstRefresh + Int64(frame)) * refreshNs).rounded()) + 500_000
      return BenchObservation(ptsNs: ptsNs, callbackNs: ptsNs + 4_000_000, reading: .version(frame))
    }
  }

  private static func bursts(hostAheadNs: Int64) -> [[BenchClockExchange]] {
    (0..<40).map { burst in
      (0..<16).map { probe in
        let sentNs = originNs + Int64(burst) * 2_000_000_000 + Int64(probe) * 1_000_000
        return BenchClockExchange(
          localSendNs: sentNs, remoteReceiveNs: sentNs + 100_000 + hostAheadNs,
          remoteSendNs: sentNs + 110_000 + hostAheadNs, localReceiveNs: sentNs + 210_000)
      }
    }
  }
}
