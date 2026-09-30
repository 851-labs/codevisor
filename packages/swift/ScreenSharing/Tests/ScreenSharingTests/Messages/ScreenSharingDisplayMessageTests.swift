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

  /// The video format channel's wire format (851-2380).
  @Test func everyVideoFormatMessageSurvivesTheWire() throws {
    for message: ScreenSharingVideoFormatMessage in [
      .viewer(highDynamicRange: true), .viewer(highDynamicRange: false), .sending(.high, reason: nil),
      .sending(.standard, reason: "The shared display has no HDR headroom."),
    ] {
      #expect(try ScreenSharingVideoFormatMessage.decode(message.encoded()) == message)
    }
    #expect(throws: (any Error).self) {
      try ScreenSharingVideoFormatMessage.decode(
        Data(#"{"version":2,"message":{"viewer":{"highDynamicRange":true}}}"#.utf8))
    }
  }
}
