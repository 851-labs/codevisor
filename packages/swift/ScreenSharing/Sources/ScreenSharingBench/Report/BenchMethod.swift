public struct BenchMethod: Codable, Sendable, Hashable {
  public var durationS: Int
  public var warmUpS: Int
  public var repetitions: Int
  public var plan: String?

  public init(durationS: Int, warmUpS: Int, repetitions: Int, plan: String? = nil) {
    self.durationS = durationS
    self.warmUpS = warmUpS
    self.repetitions = repetitions
    self.plan = plan
  }
}
