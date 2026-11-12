import Foundation
import ScreenSharingV2
import Testing

struct ScreenSharingConnectTimesTests {
  @Test func theSummaryAddsUpEachStageIncludingOnesEnteredTwice() {
    let start = ContinuousClock.now
    var times = ScreenSharingConnectTimes(at: start)
    times.enter(.connectingMedia, at: start + .milliseconds(200))
    times.enter(.startingHost, at: start + .milliseconds(300))
    times.enter(.connectingMedia, at: start + .milliseconds(1200))
    times.enter(.handshake, at: start + .milliseconds(1400))
    times.enter(.waitingForVideo, at: start + .milliseconds(1500))

    #expect(
      times.summary(at: start + .milliseconds(2400))
        == "2.4 s (reach 0.2 · start 0.9 · media 0.3 · handshake 0.1 · video 0.9)")
    #expect(times.stage == .waitingForVideo)
  }
}
