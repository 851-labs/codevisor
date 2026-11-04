import Testing

@testable import ScreenSharingV2

struct ScreenSharingVCPRateTests {
  @Test func refinementPassesGoNearLosslessOnlyFromTheBottomOfApplesLadder() {
    let fast = ScreenSharingVCPRate(bitsPerSecond: ScreenSharingVCPRate.ladder.lowerBound, tiles: 4)
    let constrained = ScreenSharingVCPRate(bitsPerSecond: ScreenSharingVCPRate.ladder.lowerBound - 1, tiles: 4)

    #expect(fast.highestQP(refining: true) == ScreenSharingVCPRate.highestRefinementQP)
    #expect(constrained.highestQP(refining: true) == ScreenSharingVCPRate.highestFrameQP)
    #expect(fast.highestQP(refining: false) == ScreenSharingVCPRate.highestFrameQP)
  }
}
