public struct BenchTimingFrameCheck: Codable, Sendable, Equatable {
  public struct Span: Codable, Sendable, Equatable {
    public var timingFramesP50Ms: Double
    public var stagesP50Ms: Double
    public var deltaP50Ms: Double

    init?(_ pairs: [(timing: Double, stages: Double)]) {
      guard let timing = BenchDistribution(pairs.map(\.timing)), let stages = BenchDistribution(pairs.map(\.stages)),
        let delta = BenchDistribution(pairs.map { $0.stages - $0.timing })
      else { return nil }

      timingFramesP50Ms = timing.p50
      stagesP50Ms = stages.p50
      deltaP50Ms = delta.p50
    }
  }

  public static let toleranceMs = 5.0
  public static let matchWindowNs: Int64 = 8_000_000
  private static let nanosecondsPerMillisecond = 1_000_000.0

  public var count: Int
  public var encode: Span
  public var decode: Span
  public var captureToDecoded: Span
  public var agrees: Bool

  public init?(timingFrames: [BenchTimingFrame], frames: [BenchFrameTimestamps], timingClockOffsetNs: Int64) {
    let pairs = timingFrames.compactMap { timing in
      Self.frame(capturedAt: Int64(timing.captureMs * Self.nanosecondsPerMillisecond) + timingClockOffsetNs, in: frames)
        .map { (timing: timing, frame: $0) }
    }
    guard
      let encode = Span(pairs.map { ($0.timing.encodeMs, Self.ms($0.frame.encodeSubmitNs, $0.frame.encodeOutputNs)) }),
      let decode = Span(pairs.map { ($0.timing.decodeMs, Self.ms($0.frame.decodeInputNs, $0.frame.decodeOutputNs)) }),
      let captureToDecoded = Span(
        pairs.map { ($0.timing.captureToDecodedMs, Self.ms($0.frame.sourceNs, $0.frame.decodeOutputNs)) })
    else { return nil }

    count = pairs.count
    self.encode = encode
    self.decode = decode
    self.captureToDecoded = captureToDecoded
    agrees = [encode, decode, captureToDecoded].allSatisfy { abs($0.deltaP50Ms) <= Self.toleranceMs }
  }

  private static func frame(capturedAt captureNs: Int64, in frames: [BenchFrameTimestamps]) -> BenchFrameTimestamps? {
    let nearest = frames.min { abs($0.sourceNs - captureNs) < abs($1.sourceNs - captureNs) }
    guard let nearest, abs(nearest.sourceNs - captureNs) <= matchWindowNs else { return nil }

    return nearest
  }

  private static func ms(_ startNs: Int64, _ endNs: Int64) -> Double {
    Double(endNs - startNs) / nanosecondsPerMillisecond
  }
}
