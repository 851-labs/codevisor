import Testing

@testable import ScreenSharingV2

struct ScreenSharingV2CaptureSlotTests {
  @Test func theNewestWaitingCaptureReplacesAnOlderOneAndARequeueReusesTheLastEncodedOne() throws {
    var slot = ScreenSharingV2CaptureSlot(tiles: [])
    let older = ScreenSharingV2Capture(frame: try TestPixels.frame(shade: 1, timestampNs: 1), capturedNs: 1)
    let newer = ScreenSharingV2Capture(frame: try TestPixels.frame(shade: 2, timestampNs: 2), capturedNs: 2)

    let replacedNothing = slot.offer(older, tiles: [0])
    let replacedOlder = slot.offer(newer, tiles: [2])
    #expect(!replacedNothing && replacedOlder)
    #expect(slot.waiting?.frame.timestampNs == 2)
    #expect(slot.waitingTiles == [0, 2])

    slot.encoding(newer)
    #expect(slot.waiting == nil)
    slot.requeue(tiles: [1])
    #expect(slot.waiting?.frame.timestampNs == 2)
    #expect(slot.waitingTiles == [1])
  }
}
