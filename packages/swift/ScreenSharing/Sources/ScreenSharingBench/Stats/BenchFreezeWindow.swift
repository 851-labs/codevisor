struct BenchFreezeWindow {
  static let length = 30
  static let multiplier = 3.0
  static let minimumIncreaseMs = 150.0

  private var gapsMs: [Double] = []

  func isFreeze(_ gapMs: Double) -> Bool {
    guard gapsMs.count == Self.length else { return false }

    let average = gapsMs.reduce(0, +) / Double(Self.length)
    return gapMs >= max(Self.multiplier * average, average + Self.minimumIncreaseMs)
  }

  mutating func append(_ gapMs: Double) {
    gapsMs.append(gapMs)
    if gapsMs.count > Self.length { gapsMs.removeFirst() }
  }
}
