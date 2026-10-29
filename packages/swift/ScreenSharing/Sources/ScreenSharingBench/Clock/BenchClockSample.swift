struct BenchClockSample {
  let localNs: Int64
  let offsetNs: Double
  let errorBoundNs: Double

  static func minimumRoundTrip(in burst: [BenchClockExchange]) -> BenchClockSample? {
    guard let best = burst.min(by: { $0.roundTripNs < $1.roundTripNs }) else { return nil }

    return BenchClockSample(
      localNs: best.localMidpointNs, offsetNs: best.offsetNs, errorBoundNs: Double(best.roundTripNs) / 2)
  }
}
