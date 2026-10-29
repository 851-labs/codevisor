public struct BenchClockEstimate: Sendable, Equatable {
  public let quality: BenchClockQuality
  private let referenceNs: Int64
  private let offsetAtReferenceNs: Double
  private let drift: Double

  public init?(bursts: [[BenchClockExchange]]) {
    let samples = bursts.compactMap(BenchClockSample.minimumRoundTrip(in:))
    guard let reference = samples.first?.localNs else { return nil }

    let fit = BenchClockFit(samples, referenceNs: reference)
    referenceNs = reference
    offsetAtReferenceNs = fit.intercept
    drift = fit.slope
    quality = BenchClockQuality(
      epsilonMs: Self.milliseconds(samples.map(\.errorBoundNs).max() ?? 0), driftPpm: fit.slope * 1_000_000,
      residualMs: Self.milliseconds(fit.maximumResidual))
  }

  public func offsetNs(atLocal localNs: Int64) -> Double {
    offsetAtReferenceNs + drift * Double(localNs - referenceNs)
  }

  public func localNs(fromRemote remoteNs: Int64) -> Int64 {
    let elapsed = (Double(remoteNs - referenceNs) - offsetAtReferenceNs) / (1 + drift)
    return referenceNs + Int64(elapsed.rounded())
  }

  private static func milliseconds(_ nanoseconds: Double) -> Double {
    nanoseconds / 1_000_000
  }
}
