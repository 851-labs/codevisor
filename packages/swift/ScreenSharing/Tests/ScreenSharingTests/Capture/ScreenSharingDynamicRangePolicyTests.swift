import CoreGraphics
import Testing

@testable import ScreenSharing

/// 851-2380: the host sends HDR only when the viewer's screen can show it, the codec has a 10-bit
/// profile and the captured display has headroom; otherwise SDR, with the reason the viewer is told.
@MainActor
struct ScreenSharingDynamicRangePolicyTests {
  @Test func hdrNeedsAViewerThatCanShowItMain444AndHeadroom() {
    let decide = ScreenSharingDynamicRangePolicy.decide
    #expect(decide(true, .hevc444, 16) == (.high, nil))
    // A viewer that can't show HDR gets SDR, and needs no reason.
    #expect(decide(false, .hevc444, 16) == (.standard, nil))
    #expect(decide(true, .hevc, 16) == (.standard, "The video codec has no HDR profile."))
    #expect(decide(true, .h264, 16).range == .standard)
    #expect(decide(true, nil, 16).range == .standard)
    // An SDR display, or Dynamic Resolution's virtual display.
    #expect(decide(true, .hevc444, 1) == (.standard, "The shared display can't show HDR."))
  }

  @Test func aDisplayThatIsntOnlineHasNoHeadroom() {
    #expect(ScreenSharingDynamicRangePolicy.headroom(of: CGDirectDisplayID.max) == 1)
  }
}
