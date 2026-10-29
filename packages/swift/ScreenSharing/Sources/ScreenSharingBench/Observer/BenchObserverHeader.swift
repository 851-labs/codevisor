public struct BenchObserverHeader: Codable, Sendable, Equatable {
  public static let currentSchema = "codevisor.screen-sharing.bench.observer/v1"
  public static let continuousClock = "mach_continuous_ns"

  public var schema: String
  public var clock: String
  public var continuousMinusAbsoluteNs: Int64
  public var machine: String
  public var source: String
  public var observerCpuPct: Double?
  public var observerPowerMw: Double?

  public init(
    machine: String, source: String, continuousMinusAbsoluteNs: Int64, observerCpuPct: Double? = nil,
    observerPowerMw: Double? = nil
  ) {
    schema = Self.currentSchema
    clock = Self.continuousClock
    self.continuousMinusAbsoluteNs = continuousMinusAbsoluteNs
    self.machine = machine
    self.source = source
    self.observerCpuPct = observerCpuPct
    self.observerPowerMw = observerPowerMw
  }
}
