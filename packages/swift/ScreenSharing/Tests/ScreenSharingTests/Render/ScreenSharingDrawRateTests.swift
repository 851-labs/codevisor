import Testing
@testable import ScreenSharing

/// The viewer draws at a whole fraction of the display's refresh that reaches 60 (851-2374):
/// asking for 60 on a 72 Hz display got 36, which was the native viewer's 30 fps ceiling.
struct ScreenSharingDrawRateTests {
  @Test(arguments: [
    (60, 60), (72, 72), (75, 75), (90, 90), (100, 100), (120, 60), (144, 72), (165, 82), (240, 60), (50, 50), (30, 30),
  ])
  func eachDisplayGetsTheSmallestWholeFractionThatReachesSixty(refresh: Int, rate: Int) {
    #expect(ScreenSharingMetalView.drawRate(displayRefresh: refresh) == rate)
  }

  @Test func anUnknownRefreshStillDraws() {
    #expect(ScreenSharingMetalView.drawRate(displayRefresh: 0) == 1)
  }
}
