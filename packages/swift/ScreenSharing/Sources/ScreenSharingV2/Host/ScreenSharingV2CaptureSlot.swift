struct ScreenSharingV2CaptureSlot {
  private(set) var waiting: ScreenSharingV2Capture?
  private(set) var waitingTiles: Set<Int>
  private(set) var lastEncoded: ScreenSharingV2Capture?

  init(tiles: Set<Int>) {
    waitingTiles = tiles
  }

  mutating func offer(_ capture: ScreenSharingV2Capture, tiles: Set<Int>) -> Bool {
    defer {
      waiting = capture
      waitingTiles.formUnion(tiles)
    }
    return waiting != nil
  }

  mutating func encoding(_ capture: ScreenSharingV2Capture) {
    waiting = nil
    waitingTiles = []
    lastEncoded = capture
  }

  mutating func requeue(tiles: Set<Int>) {
    guard let capture = waiting ?? lastEncoded else { return }

    waiting = capture
    waitingTiles.formUnion(tiles)
  }

  mutating func clear() {
    waiting = nil
    waitingTiles = []
    lastEncoded = nil
  }
}
