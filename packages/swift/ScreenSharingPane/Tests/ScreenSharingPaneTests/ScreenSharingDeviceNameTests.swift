import Testing

@testable import ScreenSharingPane

struct ScreenSharingDeviceNameTests {
  @Test(
    "The name sent to other devices is the phone's name without control characters, at most 64 long, never empty",
    arguments: [
      ("Alexandru's iPhone", "Alexandru's iPhone"),
      ("  Work\u{7}\nPhone\u{2028} ", "WorkPhone"),
      (String(repeating: "é", count: 80), String(repeating: "é", count: 64)),
      (" \t\u{0}\u{2029}", "iPhone"),
      ("", "iPhone"),
    ])
  func sanitises(name: String, sent: String) {
    #expect(ScreenSharingDeviceName.sanitised(name) == sent)
  }
}
