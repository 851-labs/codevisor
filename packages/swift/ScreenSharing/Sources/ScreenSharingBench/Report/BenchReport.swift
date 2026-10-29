public struct BenchReport: Codable, Sendable, Equatable {
  public static let schemaIdentifier = "codevisor.screen-sharing.bench/v1"
  public static let tiers: ClosedRange<Int> = 1...3

  public var schema: String
  public var run: BenchRun
  public var environment: BenchEnvironment
  public var calibration: BenchCalibration
  public var results: [BenchResult]
  public var comparisons: [BenchComparison]

  public init(
    run: BenchRun, environment: BenchEnvironment, calibration: BenchCalibration = BenchCalibration(),
    results: [BenchResult] = [], comparisons: [BenchComparison] = []
  ) {
    schema = Self.schemaIdentifier
    self.run = run
    self.environment = environment
    self.calibration = calibration
    self.results = results
    self.comparisons = comparisons
  }

  public var validationIssues: [String] {
    var issues: [String] = []
    if schema != Self.schemaIdentifier { issues.append("schema is \(schema), expected \(Self.schemaIdentifier)") }
    if !Self.tiers.contains(run.tier) { issues.append("run.tier \(run.tier) is not 1, 2 or 3") }
    for (index, result) in results.enumerated() {
      issues += result.validationIssues.map { "results[\(index)]: \($0)" }
    }
    for (index, comparison) in comparisons.enumerated() {
      issues += comparison.validationIssues.map { "comparisons[\(index)]: \($0)" }
    }
    return issues
  }
}
