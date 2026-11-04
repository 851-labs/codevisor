import Testing

@testable import CodevisorBench

struct EncodeLabSettledFramesTests {
  @Test func picksTheLastPassOfEachVersionHeldLongEnoughAfterWarmUp() {
    let events = [
      event(frame: 0, version: 0, tick: 0), event(frame: 1, version: 0, tick: 2),
      event(frame: 2, version: 1, tick: 40), event(frame: 3, version: 1, tick: 42),
      event(frame: 4, version: 2, tick: 50),
      event(frame: 5, version: 3, tick: 90), event(frame: 6, version: 3, tick: 92),
    ]

    let settled = EncodeLabSettledFrames.select(events, endTick: 130, from: 10)

    #expect(settled == [4, 6])
  }

  @Test func keepsAVersionHeldUntilTheEndOfTheRun() {
    let events = [event(frame: 0, version: 0, tick: 20), event(frame: 1, version: 0, tick: 22)]

    #expect(EncodeLabSettledFrames.select(events, endTick: 50, from: 0) == [1])
    #expect(EncodeLabSettledFrames.select(events, endTick: 49, from: 0) == [])
  }

  private func event(frame: Int, version: Int, tick: Int) -> EncodeLabFrameEvent {
    EncodeLabFrameEvent(
      frame: frame, version: version, tick: tick, scheduledNs: 0, preparedNs: 0, submittedNs: 0, returnedNs: 0,
      encodedTiles: [0], dirtyTiles: 1, refresh: nil, repeats: false)
  }
}
