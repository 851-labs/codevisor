public struct BenchSceneCadence: Sendable, Equatable {
  public let changeIntervalMs: Double
  public let changesContinuously: Bool

  public init(changeIntervalMs: Double, changesContinuously: Bool) {
    self.changeIntervalMs = changeIntervalMs
    self.changesContinuously = changesContinuously
  }
}
