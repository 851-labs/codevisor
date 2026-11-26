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

  @Test func aSmallChangeStaysSmallOnlyUntilItsTileChangesAgainIsEncodedOrIsQueuedAgain() throws {
    var slot = ScreenSharingV2CaptureSlot(tiles: [])
    let captures = try (1...3).map { index in
      ScreenSharingV2Capture(
        frame: try TestPixels.frame(shade: UInt8(index), timestampNs: Int64(index)), capturedNs: Int64(index))
    }

    _ = slot.offer(captures[0], tiles: [0, 1], small: [0, 1])
    _ = slot.offer(captures[1], tiles: [2], changedAgain: [1])
    let whileWaiting = slot.smallTiles
    slot.encoding(captures[1])
    let onceEncoding = slot.smallTiles
    _ = slot.offer(captures[2], tiles: [3], small: [3])
    slot.requeue(tiles: [3])

    #expect(whileWaiting == [0])
    #expect(onceEncoding.isEmpty)
    #expect(slot.waitingTiles == [3])
    #expect(slot.smallTiles.isEmpty)
  }
}
