struct ScreenSharingV2CaptureSlot {
  private(set) var waiting: ScreenSharingV2Capture?
  private(set) var lastEncoded: ScreenSharingV2Capture?

  mutating func offer(_ capture: ScreenSharingV2Capture) -> Bool {
    defer { waiting = capture }
    return waiting != nil
  }

  func next(refreshing: Bool) -> ScreenSharingV2Capture? {
    waiting ?? (refreshing ? lastEncoded : nil)
  }

  mutating func encoding(_ capture: ScreenSharingV2Capture) {
    waiting = nil
    lastEncoded = capture
  }

  mutating func requeueLastEncoded() {
    waiting = waiting ?? lastEncoded
  }

  mutating func clear() {
    waiting = nil
    lastEncoded = nil
  }
}
