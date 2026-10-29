public struct BenchStageTimings: Codable, Sendable, Equatable {
  public var capture: BenchDistribution?
  public var captureQueue: BenchDistribution?
  public var encode: BenchDistribution?
  public var send: BenchDistribution?
  public var receive: BenchDistribution?
  public var decodeQueue: BenchDistribution?
  public var decode: BenchDistribution?
  public var renderQueue: BenchDistribution?
  public var present: BenchDistribution?
  public var networkResidual: BenchDistribution?

  public init() {}
}
