import ScreenSharingBench
import Testing

@testable import CodevisorBench

struct Tier2BottomTileTests {
  @Test func aFrameWhoseTwoBarcodesShowDifferentVersionsCountsAsTorn() {
    let top = Self.observations([(1_000_000, 1), (17_000_000, 2), (33_000_000, 3), (50_000_000, 4)])
    let bottom = Self.observations([(1_200_000, 1), (17_100_000, 1), (33_000_000, 3), (50_000_000, 4)])

    #expect(Tier2BottomTile.tornFraction(top: top, bottom: bottom) { _ in true } == 0.25)
  }

  @Test func onlyFramesInsideTheWindowAndWithinTwoMillisecondsOfEachOtherArePaired() {
    let top = Self.observations([(1_000_000, 1), (17_000_000, 2), (33_000_000, 3)])
    let bottom = Self.observations([(1_000_000, 9), (20_000_000, 1), (33_000_000, 3)])

    let fraction = Tier2BottomTile.tornFraction(top: top, bottom: bottom) { $0 > 10_000_000 }

    #expect(fraction == 0)
  }

  @Test func noPairedFramesGiveNoTornShare() {
    let top = Self.observations([(1_000_000, 1)])

    #expect(Tier2BottomTile.tornFraction(top: top, bottom: []) { _ in true } == nil)
  }

  private static func observations(_ frames: [(Int64, Int)]) -> [BenchObservation] {
    frames.map { BenchObservation(ptsNs: $0.0, callbackNs: $0.0, reading: .version($0.1)) }
  }
}
