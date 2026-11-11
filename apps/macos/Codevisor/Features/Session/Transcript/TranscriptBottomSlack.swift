import Foundation

struct TranscriptBottomSlack {
  private static let idleHold: TimeInterval = 0.6
  private static let halfLife: TimeInterval = 0.07
  private static let settledHeight: CGFloat = 0.5
  private static let longestStep: TimeInterval = 1.0 / 30
  private static let heldLimit: CGFloat = 120

  private(set) var height: CGFloat = 0
  private var changedAt: TimeInterval = 0
  private var decayedAt: TimeInterval?

  var isActive: Bool { height > 0 }

  mutating func absorb(rowsHeightChange change: CGFloat, at time: TimeInterval) {
    guard abs(change) > Self.settledHeight else { return }

    height = max(0, height - change)
    changedAt = time
    decayedAt = nil
    if height < Self.settledHeight { height = 0 }
  }

  mutating func decay(at time: TimeInterval) -> Bool {
    let isIdle = time - changedAt >= Self.idleHold
    let floor = isIdle ? 0 : Self.heldLimit
    guard height > floor else { return false }

    let elapsed = time - (decayedAt ?? (isIdle ? changedAt + Self.idleHold : time - 1.0 / 60))
    decayedAt = time
    let factor = pow(0.5, min(max(0, elapsed), Self.longestStep) / Self.halfLife)
    height = floor + (height - floor) * factor
    if height < Self.settledHeight { height = 0 }
    return true
  }

  mutating func reset() {
    self = TranscriptBottomSlack()
  }
}
