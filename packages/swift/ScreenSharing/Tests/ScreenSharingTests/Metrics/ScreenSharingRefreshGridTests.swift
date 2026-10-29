import Testing
@testable import ScreenSharing

struct ScreenSharingRefreshGridTests {
  private let grid = ScreenSharingRefreshGrid(targetNs: 1_000, periodNs: 100)

  @Test(arguments: [(1_000, 1_000), (1_001, 1_100), (1_099, 1_100), (1_100, 1_100), (2_050, 2_100), (950, 1_000)])
  func aTimeLandsOnTheFirstRefreshAtOrAfterIt(time: Int64, refresh: Int64) {
    #expect(grid.firstRefresh(atOrAfter: time) == refresh)
  }

  @Test func aFrameReachesTheGlassOneRefreshAfterTheRefreshItWasReadyFor() {
    #expect(grid.onGlass(afterGPUCompletionAt: 1_001) == 1_200)
    #expect(grid.onGlass(afterGPUCompletionAt: 1_100) == 1_200)
  }

  @Test func aGridWithoutAPeriodHasNoRefreshes() {
    #expect(ScreenSharingRefreshGrid(targetNs: 1_000, periodNs: 0).firstRefresh(atOrAfter: 1_000) == nil)
  }
}
