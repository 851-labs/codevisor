public struct BenchProcessLoad: Sendable, Equatable {
  private static let percent = 100.0
  private static let milliwattsPerNanojoulePerNs = 1_000.0

  public let cpuPercent: Double
  public let powerMw: Double

  public init(cpuPercent: Double, powerMw: Double) {
    self.cpuPercent = cpuPercent
    self.powerMw = powerMw
  }

  public init?(from earlier: BenchProcessUsage, to later: BenchProcessUsage) {
    let elapsedNs = Double(later.sampledNs - earlier.sampledNs)
    guard elapsedNs > 0 else { return nil }

    cpuPercent = Double(later.cpuNs - earlier.cpuNs) / elapsedNs * Self.percent
    powerMw = Double(later.energyNj - earlier.energyNj) / elapsedNs * Self.milliwattsPerNanojoulePerNs
  }
}
