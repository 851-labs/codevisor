import Foundation

struct TranscriptBottomSlack {
  private static let hold: TimeInterval = 0.12
  private static let halfLife: TimeInterval = 0.07
  private static let settledHeight: CGFloat = 0.5
  private static let longestStep: TimeInterval = 1.0 / 30

  private(set) var height: CGFloat = 0
  private var absorbedAt: TimeInterval = 0
  private var decayedAt: TimeInterval?

  var isActive: Bool { height > 0 }

  mutating func absorb(rowsHeightChange change: CGFloat, at time: TimeInterval) {
    height = max(0, height - change)
    if change < 0 {
      absorbedAt = time
      decayedAt = nil
    }
    if height < Self.settledHeight { height = 0 }
  }

  mutating func decay(at time: TimeInterval) -> Bool {
    guard isActive, time - absorbedAt >= Self.hold else { return false }

    let elapsed = time - (decayedAt ?? absorbedAt + Self.hold)
    decayedAt = time
    height *= pow(0.5, min(max(0, elapsed), Self.longestStep) / Self.halfLife)
    if height < Self.settledHeight { height = 0 }
    return true
  }

  mutating func reset() {
    self = TranscriptBottomSlack()
  }
}
