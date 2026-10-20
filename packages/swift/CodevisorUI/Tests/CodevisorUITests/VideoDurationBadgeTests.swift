import Testing

@testable import CodevisorUI

struct VideoDurationBadgeTests {
  @Test(arguments: [
    (0.2, "0:00"),
    (4.6, "0:05"),
    (59.5, "1:00"),
    (754, "12:34"),
    (3_723, "1:02:03"),
  ])
  func labelsDurationsLikeAVideoPlayer(seconds: Double, label: String) {
    #expect(VideoDurationBadge.label(seconds: seconds) == label)
  }
}
