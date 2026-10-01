import ScreenSharing
import Testing
@testable import CodevisorCoreMac

@MainActor
struct ScreenSharingHostStreamTests {
  @Test func audioSubscriptionIsIdempotentAndChannelLossStopsCapture() {
    let (channel, _) = ScreenSharingLocalChannel<ScreenSharingAudioMessage>.pair()
    let metrics = ScreenSharingMetrics()
    var captureChanges: [Bool] = []
    let stream = ScreenSharingHostAudioStream(
      channel: channel, sendPacket: { _ in true }, tap: ScreenSharingCaptureAudioTap(), metrics: metrics,
      isStopping: { false }, setCapturesAudio: { captureChanges.append($0) })
    channel.onMessage?(.subscribe)
    channel.onMessage?(.subscribe)
    #expect(captureChanges == [true])
    #expect(metrics.snapshot().labels["audioStream"] == "on")
    channel.onMessage?(.unsubscribe)
    channel.onMessage?(.unsubscribe)
    #expect(captureChanges == [true, false])
    channel.onMessage?(.subscribe)
    channel.close()
    #expect(captureChanges == [true, false, true, false])
    #expect(metrics.snapshot().labels["audioStream"] == "off")
    withExtendedLifetime(stream) {}
  }

  @Test func audioShutdownRejectsLateSubscriptionsWithoutRestartingCapture() {
    let (channel, _) = ScreenSharingLocalChannel<ScreenSharingAudioMessage>.pair()
    let metrics = ScreenSharingMetrics()
    var stopping = false
    var captureChanges: [Bool] = []
    let stream = ScreenSharingHostAudioStream(
      channel: channel, sendPacket: { _ in true }, tap: ScreenSharingCaptureAudioTap(), metrics: metrics,
      isStopping: { stopping }, setCapturesAudio: { captureChanges.append($0) })
    channel.onMessage?(.subscribe)
    stopping = true
    stream.detachCapture()
    channel.onMessage?(.subscribe)
    channel.close()
    #expect(captureChanges == [true])
    #expect(metrics.snapshot().labels["audioStream"] == "off")
    withExtendedLifetime(stream) {}
  }

  @Test func cursorChannelLossRestoresTheVideoCursorUnlessTheSessionIsStopping() {
    for stopsSession in [false, true] {
      let (channel, _) = ScreenSharingLocalChannel<ScreenSharingCursorMessage>.pair()
      let metrics = ScreenSharingMetrics()
      var stopping = false
      var cursorChanges: [Bool] = []
      let stream = ScreenSharingHostCursorStream(
        channel: channel, displayID: 0, metrics: metrics,
        isStopping: { stopping }, setShowsCursor: { cursorChanges.append($0) })
      channel.onMessage?(.subscribe)
      channel.onMessage?(.subscribe)
      #expect(cursorChanges == [false])
      #expect(metrics.snapshot().labels["cursorStream"] == "on")
      stopping = stopsSession
      stream.stopPublishing()
      channel.onMessage?(.subscribe)
      channel.close()
      #expect(cursorChanges == (stopsSession ? [false] : [false, true]))
      #expect(metrics.snapshot().labels["cursorStream"] == "closed")
      withExtendedLifetime(stream) {}
    }
  }
}
