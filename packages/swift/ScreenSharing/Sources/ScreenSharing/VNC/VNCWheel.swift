public enum VNCScrollInput: Sendable {
  case wheel
  case touch
}

struct VNCWheel {
  static let pixelsPerClick = 20.0
  static let maximumClicksPerEvent = 8
  static let leftoverLifetime: Duration = .milliseconds(300)

  private let input: VNCScrollInput
  private var leftover = 0.0
  private var lastTouch: ContinuousClock.Instant?

  init(input: VNCScrollInput) {
    self.input = input
  }

  mutating func clicks(for delta: Int32, at now: ContinuousClock.Instant) -> Int {
    guard delta != 0 else { return 0 }

    switch input {
    case .wheel: return wheelClicks(for: delta)
    case .touch: return touchClicks(for: delta, at: now)
    }
  }

  private func wheelClicks(for delta: Int32) -> Int {
    let clicks = max(1, Int((Double(abs(delta)) / Self.pixelsPerClick).rounded()))
    return min(Self.maximumClicksPerEvent, clicks) * Int(delta.signum())
  }

  private mutating func touchClicks(for delta: Int32, at now: ContinuousClock.Instant) -> Int {
    if let lastTouch, now - lastTouch > Self.leftoverLifetime { leftover = 0 }
    lastTouch = now

    leftover += Double(delta)
    let whole = Int(leftover / Self.pixelsPerClick)
    leftover -= Double(whole) * Self.pixelsPerClick
    return min(Self.maximumClicksPerEvent, max(-Self.maximumClicksPerEvent, whole))
  }
}
