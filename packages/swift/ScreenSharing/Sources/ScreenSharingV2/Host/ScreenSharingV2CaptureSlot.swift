struct ScreenSharingV2CaptureSlot {
  private(set) var waiting: ScreenSharingV2Capture?
  private(set) var waitingTiles: Set<Int>
  private(set) var smallTiles: Set<Int> = []
  private(set) var lastEncoded: ScreenSharingV2Capture?
  private(set) var repeatedTiles: Set<Int> = []

  init(tiles: Set<Int>) {
    waitingTiles = tiles
  }

  mutating func offer(
    _ capture: ScreenSharingV2Capture, tiles: Set<Int>, small: Set<Int> = [], changedAgain: Set<Int> = []
  ) -> Bool {
    defer {
      waiting = capture
      repeatedTiles = []
      waitingTiles.formUnion(tiles)
      smallTiles = smallTiles.subtracting(changedAgain).subtracting(tiles).union(small)
    }
    return waiting != nil
  }

  mutating func encoding(_ capture: ScreenSharingV2Capture) {
    waiting = nil
    repeatedTiles = []
    waitingTiles = []
    smallTiles = []
    lastEncoded = capture
  }

  mutating func requeue(tiles: Set<Int>, repeating: Bool = false) {
    guard let capture = waiting ?? lastEncoded else { return }

    if repeating, waiting.map({ $0.capturedNs == lastEncoded?.capturedNs }) ?? true {
      repeatedTiles.formUnion(tiles)
    } else {
      repeatedTiles.subtract(tiles)
    }
    waiting = capture
    waitingTiles.formUnion(tiles)
    smallTiles.subtract(tiles)
  }

  mutating func clear() {
    waiting = nil
    repeatedTiles = []
    waitingTiles = []
    smallTiles = []
    lastEncoded = nil
  }
}
