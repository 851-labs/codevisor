import Foundation
import Testing
@testable import ScreenSharing

/// The display channel's wire format (851-2376).
struct ScreenSharingDisplayMessageTests {
  @Test func everyMessageSurvivesTheWire() throws {
    for message: ScreenSharingDisplayMessage in [
      .ready, .resize(width: 1280, height: 800), .restore, .resized(width: 1280, height: 800), .unavailable("no"),
    ] {
      #expect(try ScreenSharingDisplayMessage.decode(message.encoded()) == message)
    }
    #expect(throws: (any Error).self) {
      try ScreenSharingDisplayMessage.decode(Data(#"{"version":2,"message":{"ready":{}}}"#.utf8))
    }
  }
}
