import Testing

@testable import ScreenSharingV2

struct ScreenSharingV2CaptureSlotTests {
  @Test func theNewestWaitingCaptureReplacesAnOlderOneAndTheLastEncodedOneServesRefreshes() throws {
    var slot = ScreenSharingV2CaptureSlot()
    let older = ScreenSharingV2Capture(frame: try TestPixels.frame(shade: 1, timestampNs: 1), capturedNs: 1)
    let newer = ScreenSharingV2Capture(frame: try TestPixels.frame(shade: 2, timestampNs: 2), capturedNs: 2)

    let replacedNothing = slot.offer(older)
    let replacedOlder = slot.offer(newer)
    #expect(!replacedNothing && replacedOlder)
    #expect(slot.next(refreshing: false)?.frame.timestampNs == 2)

    slot.encoding(newer)
    #expect(slot.next(refreshing: false) == nil)
    #expect(slot.next(refreshing: true)?.frame.timestampNs == 2)
  }
}
