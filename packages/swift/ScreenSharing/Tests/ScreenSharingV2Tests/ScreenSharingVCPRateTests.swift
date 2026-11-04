import Testing

@testable import ScreenSharingV2

struct ScreenSharingVCPRateTests {
  @Test func refinementPassesGoNearLosslessOnlyFromTheBottomOfApplesLadder() {
    let ladder = ScreenSharingVCPRate.nearLosslessFromBitsPerSecond
    let fast = ScreenSharingVCPRate(bitsPerSecond: ladder, tiles: 4)
    let constrained = ScreenSharingVCPRate(bitsPerSecond: ladder - 1, tiles: 4)

    #expect(fast.highestQP(refining: true) == ScreenSharingVCPRate.highestRefinementQP)
    #expect(constrained.highestQP(refining: true) == ScreenSharingVCPRate.highestFrameQP)
    #expect(fast.highestQP(refining: false) == ScreenSharingVCPRate.highestFrameQP)
  }
}
