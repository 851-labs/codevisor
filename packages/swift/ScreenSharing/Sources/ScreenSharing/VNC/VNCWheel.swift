public enum VNCScrollInput: Sendable {
  case wheel
  case touch
}

struct VNCWheel {
  static let pixelsPerClick = 20.0
  static let maximumClicksPerEvent = 8

  private let input: VNCScrollInput
  private var leftover = 0.0

  init(input: VNCScrollInput) {
    self.input = input
  }

  mutating func gestureBegan() {
    leftover = 0
  }

  mutating func clicks(for delta: Int32) -> Int {
    guard delta != 0 else { return 0 }

    switch input {
    case .wheel: return wheelClicks(for: delta)
    case .touch: return touchClicks(for: delta)
    }
  }

  private func wheelClicks(for delta: Int32) -> Int {
    let clicks = max(1, Int((Double(abs(delta)) / Self.pixelsPerClick).rounded()))
    return min(Self.maximumClicksPerEvent, clicks) * Int(delta.signum())
  }

  private mutating func touchClicks(for delta: Int32) -> Int {
    leftover += Double(delta)
    let whole = Int(leftover / Self.pixelsPerClick)
    leftover -= Double(whole) * Self.pixelsPerClick
    return min(Self.maximumClicksPerEvent, max(-Self.maximumClicksPerEvent, whole))
  }
}
