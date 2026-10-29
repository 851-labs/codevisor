public struct BenchFreezes: Codable, Sendable, Equatable {
  public static let pauseThresholdMs = 5_000.0

  public var count: Int
  public var totalMs: Double
  public var ratio: Double
  public var perMinute: Double
  public var pauses: Int
  public var pausesTotalMs: Double

  public init(count: Int, totalMs: Double, ratio: Double, perMinute: Double, pauses: Int, pausesTotalMs: Double) {
    self.count = count
    self.totalMs = totalMs
    self.ratio = ratio
    self.perMinute = perMinute
    self.pauses = pauses
    self.pausesTotalMs = pausesTotalMs
  }

  public init(gapsMs: [Double], activeDurationMs: Double) {
    var window = BenchFreezeWindow()
    var freezes: [Double] = []
    var pauses: [Double] = []
    for gap in gapsMs {
      if gap > Self.pauseThresholdMs {
        pauses.append(gap)
        continue
      }
      if window.isFreeze(gap) { freezes.append(gap) }
      window.append(gap)
    }
    self.init(freezes: freezes, pauses: pauses, activeDurationMs: activeDurationMs)
  }

  private init(freezes: [Double], pauses: [Double], activeDurationMs: Double) {
    let totalMs = freezes.reduce(0, +)
    let hasActiveTime = activeDurationMs > 0
    self.init(
      count: freezes.count, totalMs: totalMs, ratio: hasActiveTime ? totalMs / activeDurationMs : 0,
      perMinute: hasActiveTime ? Double(freezes.count) * 60_000 / activeDurationMs : 0,
      pauses: pauses.count, pausesTotalMs: pauses.reduce(0, +))
  }
}
