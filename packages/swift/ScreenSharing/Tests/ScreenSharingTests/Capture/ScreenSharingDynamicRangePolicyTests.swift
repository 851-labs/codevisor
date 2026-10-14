import CoreGraphics
import Testing

@testable import ScreenSharing

@MainActor
struct ScreenSharingDynamicRangePolicyTests {
  @Test func hdrNeedsAViewerThatCanShowItMain444AndHeadroom() {
    let decide = ScreenSharingDynamicRangePolicy.decide
    #expect(decide(true, .hevc444, 16) == (.high, nil))
    #expect(decide(false, .hevc444, 16) == (.standard, nil))
    #expect(decide(true, .hevc, 16) == (.standard, "The video codec has no HDR profile."))
    #expect(decide(true, .h264, 16).range == .standard)
    #expect(decide(true, nil, 16).range == .standard)
    #expect(decide(true, .hevc444, 1) == (.standard, "The shared display can't show HDR."))
  }

  @Test func aDisplayThatIsntOnlineHasNoHeadroom() {
    #expect(ScreenSharingDynamicRangePolicy.headroom(of: CGDirectDisplayID.max) == 1)
  }
}
