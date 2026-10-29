public struct BenchClockQuality: Codable, Sendable, Equatable {
  public var epsilonMs: Double
  public var driftPpm: Double
  public var residualMs: Double

  public init(epsilonMs: Double, driftPpm: Double, residualMs: Double) {
    self.epsilonMs = epsilonMs
    self.driftPpm = driftPpm
    self.residualMs = residualMs
  }
}
