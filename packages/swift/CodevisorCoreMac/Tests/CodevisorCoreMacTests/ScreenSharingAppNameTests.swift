import Testing
@testable import CodevisorCoreMac

struct ScreenSharingAppNameTests {
  @Test(
    "The name sent to other devices is the Mac's name without control characters, at most 64 long, never empty",
    arguments: [
      ("Alexandru's MacBook Pro", "Alexandru's MacBook Pro"),
      ("  Studio\u{7}\nMac\u{2028} ", "StudioMac"),
      (String(repeating: "é", count: 80), String(repeating: "é", count: 64)),
      (" \t\u{0}\u{2029}", "Mac"),
      ("", "Mac"),
    ])
  func sanitises(name: String, sent: String) {
    #expect(ScreenSharingAppName.sanitised(name) == sent)
  }

  @Test func fallsBackWhenTheMacHasNoName() {
    #expect(ScreenSharingAppName.sanitised(nil) == "Mac")
    #expect(!ScreenSharingAppName.current.isEmpty)
  }
}
