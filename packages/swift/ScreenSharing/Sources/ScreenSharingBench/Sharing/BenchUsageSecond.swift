public struct BenchUsageSecond: Codable, Sendable, Equatable {
  public struct Process: Codable, Sendable, Equatable {
    public var cpuPct: Double
    public var powerMw: Double

    public init(cpuPct: Double, powerMw: Double) {
      self.cpuPct = cpuPct
      self.powerMw = powerMw
    }
  }

  public var endNs: Int64
  public var intervalNs: Int64
  public var receivedMbps: Double?
  public var sentMbps: Double?
  public var processes: [String: Process]

  public init(
    endNs: Int64, intervalNs: Int64, receivedMbps: Double?, sentMbps: Double?, processes: [String: Process]
  ) {
    self.endNs = endNs
    self.intervalNs = intervalNs
    self.receivedMbps = receivedMbps
    self.sentMbps = sentMbps
    self.processes = processes
  }

  public func cpuPct(of names: Set<String>) -> Double {
    processes.filter { names.contains($0.key) }.values.map(\.cpuPct).reduce(0, +)
  }

  public func powerMw(of names: Set<String>) -> Double {
    processes.filter { names.contains($0.key) }.values.map(\.powerMw).reduce(0, +)
  }
}
