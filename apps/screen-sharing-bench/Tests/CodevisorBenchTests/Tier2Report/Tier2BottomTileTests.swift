import ScreenSharingBench
import Testing

@testable import CodevisorBench

struct Tier2BottomTileTests {
  @Test func aFrameWhoseTopShowsANewerVersionThanItsBottomCountsAsTorn() {
    let top = Self.observations([(1_000_000, 1), (17_000_000, 2), (33_000_000, 3)])
    let bottom = Self.observations([(1_200_000, 1), (33_100_000, 3)])

    #expect(Tier2BottomTile.tornFraction(top: top, bottom: bottom) { _ in true } == 1.0 / 3)
  }

  @Test func aBottomThatChangesOnlyAFrameLaterIsTornForThatFrame() {
    let top = Self.observations([(1_000_000, 1), (17_000_000, 2)])
    let bottom = Self.observations([(1_000_000, 1), (33_000_000, 2)])

    #expect(Tier2BottomTile.tornFraction(top: top, bottom: bottom) { _ in true } == 1.0 / 3)
  }

  @Test func onlyFramesInsideTheWindowCount() {
    let top = Self.observations([(1_000_000, 1), (17_000_000, 2), (33_000_000, 3)])
    let bottom = Self.observations([(1_000_000, 9), (17_000_000, 2), (33_000_000, 3)])

    #expect(Tier2BottomTile.tornFraction(top: top, bottom: bottom) { $0 > 10_000_000 } == 0)
  }

  @Test func noFrameWithBothBarcodesReadGivesNoTornShare() {
    let top = Self.observations([(1_000_000, 1)])

    #expect(Tier2BottomTile.tornFraction(top: top, bottom: []) { _ in true } == nil)
  }

  private static func observations(_ frames: [(Int64, Int)]) -> [BenchObservation] {
    frames.map { BenchObservation(ptsNs: $0.0, callbackNs: $0.0, reading: .version($0.1)) }
  }
}
