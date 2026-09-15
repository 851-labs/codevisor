import Foundation

/// Preserve fractional trackpad movement when sending integral pixel deltas.
public struct ScreenSharingScrollAccumulator {
  private var x = 0.0
  private var y = 0.0
  public init() {}
  public mutating func add(x: Double, y: Double) -> (x: Int32, y: Int32) {
    guard x.isFinite, y.isFinite else { return (0, 0) }
    self.x = min(4096, max(-4096, self.x + x))
    self.y = min(4096, max(-4096, self.y + y))
    let dx = Int32(self.x); let dy = Int32(self.y)
    self.x -= Double(dx); self.y -= Double(dy)
    return (dx, dy)
  }
}
