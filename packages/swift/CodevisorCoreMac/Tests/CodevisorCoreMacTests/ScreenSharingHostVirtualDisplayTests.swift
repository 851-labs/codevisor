import ScreenSharing
import Testing
@testable import CodevisorCoreMac

/// The host's virtual display stays within what the encoder can carry (851-2376).
@MainActor
struct ScreenSharingHostVirtualDisplayTests {
  @Test func sizesKeepThePanesShapeWithinTheVideoLimit() throws {
    #expect(ScreenSharingHostVirtualDisplay.clamp(width: 1281, height: 801) == (1280, 800))
    // A tall pane (the letterboxed stream): scaled as a whole to 1080 points high, not cut to 1200.
    let tall = ScreenSharingHostVirtualDisplay.clamp(width: 1439, height: 1360)
    #expect(tall == (1142, 1080))
    #expect((try? ScreenSharingVideoConfiguration(width: tall.width * 2, height: tall.height * 2)) != nil)
    #expect(ScreenSharingHostVirtualDisplay.clamp(width: 5000, height: 2500) == (1920, 960))
    #expect(ScreenSharingHostVirtualDisplay.clamp(width: 100, height: 100) == (640, 400))
  }
}
