public struct BenchMachine: Codable, Sendable, Equatable {
  public var name: String
  public var chip: String
  public var os: String
  public var display: String
  public var load1AtStart: Double
  public var thermal: String
  public var spotlightBusy: Bool

  public init(
    name: String, chip: String, os: String, display: String, load1AtStart: Double, thermal: String,
    spotlightBusy: Bool
  ) {
    self.name = name
    self.chip = chip
    self.os = os
    self.display = display
    self.load1AtStart = load1AtStart
    self.thermal = thermal
    self.spotlightBusy = spotlightBusy
  }
}
