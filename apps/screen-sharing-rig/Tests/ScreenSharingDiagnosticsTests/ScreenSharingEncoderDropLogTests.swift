import Testing
import ScreenSharing
@testable import ScreenSharingDiagnostics

struct ScreenSharingEncoderDropLogTests {
  @Test func retainsOnlyExpectedNumericCounters() {
    let message =
      "(video_stream_encoder.cc:1686): Number of frames: captured 900, dropped (due to congestion window pushback) 12, dropped (due to encoder blocked) 210, interval_ms 60000\n"
    #expect(
      ScreenSharingEncoderDropLog.counters(in: message) == [
        "rtcLoggedInputFrames": 900, "rtcCongestionWindowDrops": 12, "rtcEncoderQueueDrops": 210,
      ])
  }

  @Test(arguments: [
    "ICE candidate with address and credentials",
    "Number of frames: captured 900, unknown counter 12, dropped (due to encoder blocked) 210, interval_ms 60000",
    "Number of frames: captured -1, dropped (due to congestion window pushback) 0, dropped (due to encoder blocked) 0, interval_ms 60000",
    "Number of frames: captured overflow, dropped (due to congestion window pushback) 0, dropped (due to encoder blocked) 0, interval_ms 60000",
  ])
  func ignoresOtherOrMalformedMessages(_ message: String) {
    #expect(ScreenSharingEncoderDropLog.counters(in: message).isEmpty)
  }

  @Test func dropDiagnosticsKeepOnlyPinnedDropMessagesWithoutAddresses() {
    let message =
      "(video_stream_encoder.cc:1643): Same/old NTP timestamp (5 <= 5) for incoming frame. Dropping. this 0x7f8a1b2c"
    #expect(
      ScreenSharingEncoderDropLog.dropDiagnostic(in: message)
        == "(video_stream_encoder.cc:1643): Same/old NTP timestamp (5 <= 5) for incoming frame. Dropping. this 0x…")
    #expect(ScreenSharingEncoderDropLog.dropDiagnostic(in: "Dropping frame. Too large for target bitrate.") != nil)
    #expect(
      ScreenSharingEncoderDropLog.dropDiagnostic(
        in:
          "Number of frames: captured 60, dropped (due to congestion window pushback) 0, dropped (due to encoder blocked) 0, interval_ms 5000"
      ) == nil)
    #expect(ScreenSharingEncoderDropLog.dropDiagnostic(in: "") == nil)
    let long = "Drop Frame: " + String(repeating: "x", count: 400)
    #expect(ScreenSharingEncoderDropLog.dropDiagnostic(in: long)?.count == 160)
  }
}
