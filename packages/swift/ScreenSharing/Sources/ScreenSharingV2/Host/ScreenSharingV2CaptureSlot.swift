struct ScreenSharingV2CaptureSlot {
  private(set) var waiting: ScreenSharingV2Capture?
  private(set) var waitingTiles: Set<Int>
  private(set) var smallTiles: Set<Int> = []
  private(set) var lastEncoded: ScreenSharingV2Capture?

  init(tiles: Set<Int>) {
    waitingTiles = tiles
  }

  mutating func offer(
    _ capture: ScreenSharingV2Capture, tiles: Set<Int>, small: Set<Int> = [], changedAgain: Set<Int> = []
  ) -> Bool {
    defer {
      waiting = capture
      waitingTiles.formUnion(tiles)
      smallTiles = smallTiles.subtracting(changedAgain).subtracting(tiles).union(small)
    }
    return waiting != nil
  }

  mutating func encoding(_ capture: ScreenSharingV2Capture) {
    waiting = nil
    waitingTiles = []
    smallTiles = []
    lastEncoded = capture
  }

  mutating func requeue(tiles: Set<Int>) {
    guard let capture = waiting ?? lastEncoded else { return }

    waiting = capture
    waitingTiles.formUnion(tiles)
    smallTiles.subtract(tiles)
  }

  mutating func clear() {
    waiting = nil
    waitingTiles = []
    smallTiles = []
    lastEncoded = nil
  }
}
