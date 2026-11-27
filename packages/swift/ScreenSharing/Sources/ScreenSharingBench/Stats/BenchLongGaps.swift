public struct BenchLongGaps: Codable, Sendable, Equatable {
  public struct Tally: Codable, Sendable, Equatable {
    public var count: Int
    public var totalMs: Double

    public init(count: Int, totalMs: Double) {
      self.count = count
      self.totalMs = totalMs
    }

    init(gapsMs: [Double], over thresholdMs: Double) {
      let long = gapsMs.filter { $0 > thresholdMs }
      self.init(count: long.count, totalMs: long.reduce(0, +))
    }
  }

  public static let shortThresholdMs = 250.0
  public static let longThresholdMs = 500.0

  public var over250Ms: Tally
  public var over500Ms: Tally

  public init(over250Ms: Tally, over500Ms: Tally) {
    self.over250Ms = over250Ms
    self.over500Ms = over500Ms
  }

  var isConsistent: Bool {
    let tallies = [over250Ms, over500Ms]
    return tallies.allSatisfy { $0.count >= 0 && $0.totalMs >= 0 }
      && over500Ms.count <= over250Ms.count && over500Ms.totalMs <= over250Ms.totalMs
  }

  public init(gapsMs: [Double]) {
    self.init(
      over250Ms: Tally(gapsMs: gapsMs, over: Self.shortThresholdMs),
      over500Ms: Tally(gapsMs: gapsMs, over: Self.longThresholdMs))
  }
}
