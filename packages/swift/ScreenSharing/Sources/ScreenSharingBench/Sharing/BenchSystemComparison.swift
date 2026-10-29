public enum BenchSystemComparison {
  public enum Better: Sendable {
    case lower
    case higher
  }

  public struct Outcome: Sendable, Equatable {
    public let noiseBand: Double
    public let verdict: BenchComparison.Verdict
  }

  public static func verdict(
    appleHp: [Double], codevisor: [Double], better: Better
  ) -> Outcome? {
    guard let apple = median(appleHp), let ours = median(codevisor) else { return nil }

    let noiseBand = max(spread(appleHp), spread(codevisor))
    let difference = ours - apple
    guard abs(difference) > noiseBand else { return Outcome(noiseBand: noiseBand, verdict: .noDifference) }

    return Outcome(
      noiseBand: noiseBand, verdict: codevisorWins(difference, better: better) ? .codevisorFaster : .appleFaster)
  }

  public static func median(_ values: [Double]) -> Double? {
    guard !values.isEmpty else { return nil }

    return BenchDistribution.nearestRank(0.5, of: values.sorted())
  }

  private static func spread(_ values: [Double]) -> Double {
    guard let low = values.min(), let high = values.max() else { return 0 }

    return high - low
  }

  private static func codevisorWins(_ difference: Double, better: Better) -> Bool {
    switch better {
    case .lower: difference < 0
    case .higher: difference > 0
    }
  }
}
