public struct BenchMethod: Codable, Sendable, Hashable {
  public var durationS: Int
  public var warmUpS: Int
  public var repetitions: Int

  public init(durationS: Int, warmUpS: Int, repetitions: Int) {
    self.durationS = durationS
    self.warmUpS = warmUpS
    self.repetitions = repetitions
  }
}
