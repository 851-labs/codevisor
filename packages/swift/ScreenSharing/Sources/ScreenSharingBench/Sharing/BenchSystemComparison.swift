public enum BenchSystemComparison {
  public static let minimumSeparatedRepetitions = 3

  public enum Better: Sendable {
    case lower
    case higher
  }

  public enum Basis: String, Sendable {
    case noiseBand = "noise band"
    case noOverlap = "no overlap"
  }

  public struct Outcome: Sendable, Equatable {
    public let noiseBand: Double
    public let verdict: BenchComparison.Verdict
    public let basis: Basis?
  }

  public static func verdict(
    appleHp: [Double], codevisor: [Double], better: Better
  ) -> Outcome? {
    guard let apple = median(appleHp), let ours = median(codevisor), let appleRange = range(appleHp),
      let ourRange = range(codevisor)
    else { return nil }

    let noiseBand = max(width(appleRange), width(ourRange))
    guard let basis = basis(ours - apple, noiseBand: noiseBand, appleHp, appleRange, codevisor, ourRange) else {
      return Outcome(noiseBand: noiseBand, verdict: .noDifference, basis: nil)
    }

    let verdict: BenchComparison.Verdict = codevisorWins(ours - apple, better: better) ? .codevisorFaster : .appleFaster
    return Outcome(noiseBand: noiseBand, verdict: verdict, basis: basis)
  }

  public static func median(_ values: [Double]) -> Double? {
    guard !values.isEmpty else { return nil }

    return BenchDistribution.nearestRank(0.5, of: values.sorted())
  }

  private static func basis(
    _ difference: Double, noiseBand: Double, _ apple: [Double], _ appleRange: ClosedRange<Double>, _ ours: [Double],
    _ ourRange: ClosedRange<Double>
  ) -> Basis? {
    if abs(difference) > noiseBand { return .noiseBand }
    guard min(apple.count, ours.count) >= minimumSeparatedRepetitions else { return nil }

    return gap(appleRange, ourRange) > min(width(appleRange), width(ourRange)) ? .noOverlap : nil
  }

  private static func range(_ values: [Double]) -> ClosedRange<Double>? {
    guard let low = values.min(), let high = values.max() else { return nil }

    return low...high
  }

  private static func width(_ range: ClosedRange<Double>) -> Double {
    range.upperBound - range.lowerBound
  }

  private static func gap(_ first: ClosedRange<Double>, _ second: ClosedRange<Double>) -> Double {
    max(second.lowerBound - first.upperBound, first.lowerBound - second.upperBound)
  }

  private static func codevisorWins(_ difference: Double, better: Better) -> Bool {
    switch better {
    case .lower: difference < 0
    case .higher: difference > 0
    }
  }
}
