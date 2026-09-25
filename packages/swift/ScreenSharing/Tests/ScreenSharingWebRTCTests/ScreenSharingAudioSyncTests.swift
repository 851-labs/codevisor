import Testing
@testable import ScreenSharingWebRTC

/// How late the viewer plays the host's sound (851-2379): as late as the picture, never under
/// 60 ms, plus a margin that grows with underruns and decays when there are none.
@MainActor
struct ScreenSharingAudioSyncTests {
  @Test func theTargetFollowsTheVideoAboveAFloor() {
    #expect(ScreenSharingReceiver.audioTarget(videoDelay: 0.03, margin: 0) == 0.06)
    #expect(ScreenSharingReceiver.audioTarget(videoDelay: 0.09, margin: 0.02) == 0.11)
  }

  @Test func underrunsWidenTheMarginWhichThenDecays() {
    var margin = ScreenSharingReceiver.audioMargin(0, newUnderruns: 3)
    #expect(abs(margin - 0.03) < 1e-9)
    margin = ScreenSharingReceiver.audioMargin(margin, newUnderruns: 0)
    #expect(abs(margin - 0.028) < 1e-9)
    #expect(ScreenSharingReceiver.audioMargin(0.11, newUnderruns: 5) == 0.12, "capped at 120 ms")
    #expect(ScreenSharingReceiver.audioMargin(0.001, newUnderruns: 0) == 0)
  }
}
