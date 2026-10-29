import ScreenSharingBench

struct ResultsHistory {
  static let trendRuns = 30

  let report: BenchReport
  let nightlies: [BenchIndexEntry]

  init(report: BenchReport, index: [BenchIndexEntry]) {
    self.report = report
    nightlies = BenchIndex.nightlies(like: report.run, in: index).filter { $0.run.id != report.run.id }
  }

  var summaries: [BenchCellSummary] {
    BenchCellSummary.summaries(report.results)
  }

  struct JudgedLatency {
    let observedMs: Double?
    let baselineMs: Double?
    let isOutsideTheJitterBuffer: Bool
  }

  func judgedLatency(_ summary: BenchCellSummary) -> JudgedLatency {
    let baseline = Array(BenchIndex.baseline(for: summary.cell, in: nightlies).suffix(BenchRegressionGate.baselineRuns))
    let run = BenchGateSample(summary)
    let outside = BenchRegressionGate.judgesOutsideTheJitterBuffer(baseline: baseline, runs: [run])
    let p50: (BenchGateSample) -> Double? = outside ? \.e2eOutsideJitterBufferP50Ms : \.e2eP50Ms
    return JudgedLatency(
      observedMs: p50(run), baselineMs: BenchMedian.of(baseline.compactMap(p50)), isOutsideTheJitterBuffer: outside)
  }

  func chart(title: String) -> ResultsChart {
    let rows = summaries.map { summary in
      ResultsChart.Row(
        label: "\(summary.cell.scene) · \(summary.cell.network)", e2eP50Ms: summary.e2eP50Ms,
        stages: summary.stagesP50Ms, history: trend(summary))
    }
    return ResultsChart(title: title, rows: rows)
  }

  private func trend(_ summary: BenchCellSummary) -> [Double] {
    let earlier = BenchIndex.baseline(for: summary.cell, in: nightlies).compactMap(\.e2eP50Ms)
    return Array((earlier + [summary.e2eP50Ms].compactMap(\.self)).suffix(Self.trendRuns))
  }
}
