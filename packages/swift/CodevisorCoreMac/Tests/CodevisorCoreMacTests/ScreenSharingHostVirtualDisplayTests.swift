import Testing
@testable import CodevisorCoreMac

/// The host's virtual display stays within what the encoder can carry (851-2376).
@MainActor
struct ScreenSharingHostVirtualDisplayTests {
  @Test func sizesAreClampedAndEven() {
    #expect(ScreenSharingHostVirtualDisplay.clamp(width: 1281, height: 801) == (1280, 800))
    #expect(ScreenSharingHostVirtualDisplay.clamp(width: 5000, height: 3000) == (1920, 1200), "3840×2400 px at most")
    #expect(ScreenSharingHostVirtualDisplay.clamp(width: 100, height: 100) == (640, 400))
  }
}
