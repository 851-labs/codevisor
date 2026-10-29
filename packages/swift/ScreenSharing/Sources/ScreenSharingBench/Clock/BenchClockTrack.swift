public struct BenchClockTrack: Sendable {
  public static let defaultHalfWindowNs: Int64 = 30_000_000_000

  public let quality: BenchClockQuality
  public let linearResidualMs: Double
  private let samples: [BenchClockSample]
  private let halfWindowNs: Int64

  public init?(bursts: [[BenchClockExchange]], halfWindowNs: Int64 = defaultHalfWindowNs) {
    let samples = bursts.compactMap(BenchClockSample.minimumRoundTrip(in:)).sorted { $0.localNs < $1.localNs }
    guard samples.count >= 2 else { return nil }

    let linear = BenchClockFit(samples, referenceNs: samples[0].localNs)
    self.samples = samples
    self.halfWindowNs = halfWindowNs
    linearResidualMs = linear.maximumResidual / 1_000_000
    quality = BenchClockQuality(
      epsilonMs: (samples.map(\.errorBoundNs).max() ?? 0) / 1_000_000, driftPpm: linear.slope * 1_000_000,
      residualMs: Self.leaveOneOutResidualNs(samples, halfWindowNs: halfWindowNs) / 1_000_000)
  }

  public func offsetNs(atLocal localNs: Int64) -> Double {
    Self.fit(around: localNs, in: samples, halfWindowNs: halfWindowNs).intercept
  }

  public func localNs(fromRemote remoteNs: Int64) -> Int64 {
    var localNs = remoteNs - Int64(offsetNs(atLocal: remoteNs).rounded())
    for _ in 0..<Self.inversionSteps {
      localNs = remoteNs - Int64(offsetNs(atLocal: localNs).rounded())
    }
    return localNs
  }

  private static let inversionSteps = 2

  private static func fit(
    around localNs: Int64, in samples: [BenchClockSample], halfWindowNs: Int64, excluding excluded: Int? = nil
  ) -> BenchClockFit {
    let window = samples.indices.filter { index in
      index != excluded && abs(samples[index].localNs - localNs) <= halfWindowNs
    }
    let nearest = window.count >= 2 ? window : nearestTwo(to: localNs, in: samples, excluding: excluded)
    return BenchClockFit(nearest.map { samples[$0] }, referenceNs: localNs)
  }

  private static func nearestTwo(to localNs: Int64, in samples: [BenchClockSample], excluding excluded: Int?) -> [Int] {
    let candidates = samples.indices.filter { $0 != excluded }
    return Array(
      candidates.sorted { abs(samples[$0].localNs - localNs) < abs(samples[$1].localNs - localNs) }.prefix(2))
  }

  private static func leaveOneOutResidualNs(_ samples: [BenchClockSample], halfWindowNs: Int64) -> Double {
    samples.indices.map { index in
      let sample = samples[index]
      return abs(
        sample.offsetNs
          - fit(around: sample.localNs, in: samples, halfWindowNs: halfWindowNs, excluding: index).intercept)
    }.max() ?? 0
  }
}
