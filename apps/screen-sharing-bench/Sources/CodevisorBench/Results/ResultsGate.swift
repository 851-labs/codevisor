import ScreenSharingBench

struct ResultsGate {
  struct Verdict {
    let first: BenchCellSummary
    let second: BenchCellSummary?
    let baseline: [BenchGateSample]
    let regressions: [BenchGateRegression]
  }

  let verdicts: [Verdict]

  init(first: BenchReport, second: BenchReport, index: [BenchIndexEntry]) {
    let nightlies = BenchIndex.nightlies(like: first.run, in: index)
    let seconds = BenchCellSummary.summaries(second.results)
    verdicts = BenchCellSummary.summaries(first.results).map { summary in
      let other = seconds.first { $0.cell == summary.cell }
      let baseline = Array(
        BenchIndex.baseline(for: summary.cell, in: nightlies).suffix(BenchRegressionGate.baselineRuns))
      let regressions = BenchRegressionGate.regressions(
        baseline: baseline, first: BenchGateSample(summary), second: other.map(BenchGateSample.init) ?? Self.missing)
      return Verdict(first: summary, second: other, baseline: baseline, regressions: regressions)
    }
  }

  var failed: Bool {
    verdicts.contains { !$0.regressions.isEmpty }
  }

  var markdown: String {
    let header = [
      "## Screen sharing regression gate: " + (failed ? "❌ regressed" : "✅ passed"), "",
      "A cell fails only when both runs cross a threshold against the median of the last "
        + "\(BenchRegressionGate.baselineRuns) nightlies (design §4.2).", "",
      "| scene | network | nightlies | e2e p50 baseline | run 1 | run 2 | e2e p95 baseline | run 1 | run 2 | result |",
      "| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |",
    ]
    return (header + verdicts.map(row)).joined(separator: "\n")
  }

  private static let missing = BenchGateSample(e2eP50Ms: nil, e2eP95Ms: nil, updatesPerS: nil, errors: 1)

  private func row(_ verdict: Verdict) -> String {
    let cells = [
      verdict.first.cell.scene, verdict.first.cell.network, "\(verdict.baseline.count)",
      format(BenchMedian.of(verdict.baseline.compactMap(\.e2eP50Ms))), format(verdict.first.e2eP50Ms),
      format(verdict.second?.e2eP50Ms), format(BenchMedian.of(verdict.baseline.compactMap(\.e2eP95Ms))),
      format(verdict.first.e2eP95Ms), format(verdict.second?.e2eP95Ms), result(verdict),
    ]
    return "| " + cells.joined(separator: " | ") + " |"
  }

  private func result(_ verdict: Verdict) -> String {
    guard verdict.regressions.isEmpty else { return "❌ " + verdict.regressions.map(\.metric).joined(separator: ", ") }

    return verdict.baseline.isEmpty ? "no baseline yet" : "✅"
  }

  private func format(_ value: Double?) -> String {
    value.map { String(format: "%.1f", $0) } ?? "–"
  }
}
