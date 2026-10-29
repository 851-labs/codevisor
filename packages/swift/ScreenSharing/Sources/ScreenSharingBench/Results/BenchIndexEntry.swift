public struct BenchIndexEntry: Codable, Sendable, Equatable {
  public var run: BenchRun
  public var path: String
  public var cells: [BenchCellSummary]

  public init(run: BenchRun, path: String, cells: [BenchCellSummary]) {
    self.run = run
    self.path = path
    self.cells = cells
  }

  public init(report: BenchReport, path: String) {
    self.init(run: report.run, path: path, cells: BenchCellSummary.summaries(report.results))
  }
}
