public struct BenchGateRegression: Sendable, Equatable {
  public let metric: String
  public let baseline: Double
  public let observed: [Double]
}

public enum BenchRegressionGate {
  public static let baselineRuns = 7

  public static func regressions(
    baseline: [BenchGateSample], first: BenchGateSample, second: BenchGateSample
  ) -> [BenchGateRegression] {
    let runs = [first, second]
    let recentBaseline = Array(baseline.suffix(baselineRuns))
    let rules = latencyRules(baseline: recentBaseline, runs: runs) + BenchGateRule.delivery
    let metricRegressions = rules.compactMap { regression(of: $0, baseline: recentBaseline, runs: runs) }
    return metricRegressions + [errorRegression(runs)].compactMap(\.self)
  }

  public static func judgesOutsideTheJitterBuffer(baseline: [BenchGateSample], runs: [BenchGateSample]) -> Bool {
    !baseline.isEmpty && (baseline + runs).allSatisfy(\.isSplitAtTheJitterBuffer)
  }

  private static func latencyRules(baseline: [BenchGateSample], runs: [BenchGateSample]) -> [BenchGateRule] {
    judgesOutsideTheJitterBuffer(baseline: baseline, runs: runs)
      ? BenchGateRule.splitAtTheJitterBuffer : BenchGateRule.e2e
  }

  private static func regression(
    of rule: BenchGateRule, baseline: [BenchGateSample], runs: [BenchGateSample]
  ) -> BenchGateRegression? {
    let observed = runs.compactMap(rule.value)
    guard observed.count == runs.count, let reference = BenchMedian.of(baseline.compactMap(rule.value)) else {
      return nil
    }
    guard observed.allSatisfy({ rule.regressed($0, from: reference) }) else { return nil }

    return BenchGateRegression(metric: rule.metric, baseline: reference, observed: observed)
  }

  private static func errorRegression(_ runs: [BenchGateSample]) -> BenchGateRegression? {
    guard runs.allSatisfy({ $0.errors > 0 }) else { return nil }

    return BenchGateRegression(metric: "errors", baseline: 0, observed: runs.map { Double($0.errors) })
  }
}
