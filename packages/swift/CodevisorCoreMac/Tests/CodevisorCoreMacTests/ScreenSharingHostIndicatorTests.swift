import Testing

@testable import CodevisorCoreMac

@MainActor
struct ScreenSharingHostIndicatorTests {
  @Test("The host's menu bar names the device viewing it, or says another device when an old app sends no name")
  func namesTheViewer() {
    #expect(
      ScreenSharingHostIndicator.title("Studio Display", viewer: "Alexandru's iPhone")
        == "Sharing Studio Display with Alexandru's iPhone")
    #expect(
      ScreenSharingHostIndicator.title("Studio Display", viewer: nil) == "Sharing Studio Display with another device")
  }
}
