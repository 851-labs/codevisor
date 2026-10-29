public struct BenchStageTimings: Codable, Sendable, Equatable {
  private static let nanosecondsPerMillisecond = 1_000_000.0

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
  public var timingFrameCheck: BenchTimingFrameCheck?

  public init() {}

  public init(frames: [BenchFrameTimestamps]) {
    capture = Self.span(frames) { ($0.sourceNs, $0.captureCallbackNs) }
    captureQueue = Self.span(frames) { ($0.captureCallbackNs, $0.encodeSubmitNs) }
    encode = Self.span(frames) { ($0.encodeSubmitNs, $0.encodeOutputNs) }
    networkResidual = Self.span(frames) { ($0.encodeOutputNs, $0.decodeInputNs) }
    decode = Self.span(frames) { ($0.decodeInputNs, $0.decodeOutputNs) }
    renderQueue = Self.span(frames) { ($0.decodeOutputNs, $0.renderCommitNs) }
    present = Self.span(frames) { frame in frame.onGlassNs.map { (frame.renderCommitNs, $0) } }
  }

  private static func span(
    _ frames: [BenchFrameTimestamps], _ endpoints: (BenchFrameTimestamps) -> (Int64, Int64)?
  ) -> BenchDistribution? {
    BenchDistribution(frames.compactMap(endpoints).map { Double($1 - $0) / nanosecondsPerMillisecond })
  }
}
