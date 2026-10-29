public struct BenchEnvironment: Codable, Sendable, Equatable {
  public var host: BenchMachine
  public var viewer: BenchMachine?
  public var link: String?
  public var clock: BenchClockQuality?

  public init(host: BenchMachine, viewer: BenchMachine? = nil, link: String? = nil, clock: BenchClockQuality? = nil) {
    self.host = host
    self.viewer = viewer
    self.link = link
    self.clock = clock
  }
}
