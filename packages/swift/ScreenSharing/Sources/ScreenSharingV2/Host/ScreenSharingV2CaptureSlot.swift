struct ScreenSharingV2CaptureSlot {
  private(set) var waiting: ScreenSharingV2Capture?
  private(set) var waitingTiles: Set<Int>
  private(set) var smallTiles: Set<Int> = []
  private(set) var lastEncoded: ScreenSharingV2Capture?
  private(set) var waitingRepeatsLastEncoded = false

  init(tiles: Set<Int>) {
    waitingTiles = tiles
  }

  mutating func offer(
    _ capture: ScreenSharingV2Capture, tiles: Set<Int>, small: Set<Int> = [], changedAgain: Set<Int> = []
  ) -> Bool {
    defer {
      waiting = capture
      waitingRepeatsLastEncoded = false
      waitingTiles.formUnion(tiles)
      smallTiles = smallTiles.subtracting(changedAgain).subtracting(tiles).union(small)
    }
    return waiting != nil
  }

  mutating func encoding(_ capture: ScreenSharingV2Capture) {
    waiting = nil
    waitingRepeatsLastEncoded = false
    waitingTiles = []
    smallTiles = []
    lastEncoded = capture
  }

  mutating func requeue(tiles: Set<Int>) {
    guard let capture = waiting ?? lastEncoded else { return }

    waitingRepeatsLastEncoded = waiting == nil || waitingRepeatsLastEncoded
    waiting = capture
    waitingTiles.formUnion(tiles)
    smallTiles.subtract(tiles)
  }

  mutating func clear() {
    waiting = nil
    waitingRepeatsLastEncoded = false
    waitingTiles = []
    smallTiles = []
    lastEncoded = nil
  }
}
