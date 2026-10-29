import ScreenSharingBench

struct ResultsGate {
  struct Verdict {
    let cell: BenchCell
    let baseline: [BenchGateSample]
    let runs: [BenchGateSample]
    let judgesOutsideTheJitterBuffer: Bool
    let regressions: [BenchGateRegression]
  }

  let verdicts: [Verdict]

  init(first: BenchReport, second: BenchReport, index: [BenchIndexEntry]) {
    let nightlies = BenchIndex.nightlies(like: first.run, in: index)
    let seconds = BenchCellSummary.summaries(second.results)
    verdicts = BenchCellSummary.summaries(first.results).map { summary in
      let baseline = Array(
        BenchIndex.baseline(for: summary.cell, in: nightlies).suffix(BenchRegressionGate.baselineRuns))
      let other = seconds.first { $0.cell == summary.cell }.map(BenchGateSample.init) ?? Self.missing
      let runs = [BenchGateSample(summary), other]
      return Verdict(
        cell: summary.cell, baseline: baseline, runs: runs,
        judgesOutsideTheJitterBuffer: BenchRegressionGate.judgesOutsideTheJitterBuffer(baseline: baseline, runs: runs),
        regressions: BenchRegressionGate.regressions(baseline: baseline, first: runs[0], second: runs[1]))
    }
  }

  var failed: Bool {
    verdicts.contains { !$0.regressions.isEmpty }
  }

  var markdown: String {
    let header = [
      "## Screen sharing regression gate: " + (failed ? "❌ regressed" : "✅ passed"), "",
      "A cell fails only when both runs cross a threshold against the median of the last "
        + "\(BenchRegressionGate.baselineRuns) nightlies (design §4.2). At N0, once the runs and every baseline nightly "
        + "split out the jitter buffer, latency is judged outside it and the jitter buffer has its own rule (p50 up "
        + "more than max(100%, 40 ms)): there WebRTC's jitter estimate sits at the product's 80 ms playout cap and "
        + "lands either at the cap or well below it from one process to the next.", "",
      "| scene | network | nightlies | latency judged | p50 baseline | run 1 | run 2 | p95 baseline | run 1 | run 2 "
        + "| jitter buffer baseline | run 1 | run 2 | result |",
      "| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |",
    ]
    return (header + verdicts.map(row)).joined(separator: "\n")
  }

  private static let missing = BenchGateSample(e2eP50Ms: nil, e2eP95Ms: nil, updatesPerS: nil, errors: 1)

  private func row(_ verdict: Verdict) -> String {
    let outside = verdict.judgesOutsideTheJitterBuffer
    let p50: (BenchGateSample) -> Double? = outside ? \.e2eOutsideJitterBufferP50Ms : \.e2eP50Ms
    let p95: (BenchGateSample) -> Double? = outside ? \.e2eOutsideJitterBufferP95Ms : \.e2eP95Ms
    let cells =
      [
        verdict.cell.scene, verdict.cell.network, "\(verdict.baseline.count)",
        outside ? "e2e outside jitter buffer" : "e2e",
      ] + columns(p50, verdict) + columns(p95, verdict) + columns(\.jitterBufferP50Ms, verdict) + [result(verdict)]
    return "| " + cells.joined(separator: " | ") + " |"
  }

  private func columns(_ value: (BenchGateSample) -> Double?, _ verdict: Verdict) -> [String] {
    [format(BenchMedian.of(verdict.baseline.compactMap(value)))] + verdict.runs.map { format(value($0)) }
  }

  private func result(_ verdict: Verdict) -> String {
    guard verdict.regressions.isEmpty else { return "❌ " + verdict.regressions.map(\.metric).joined(separator: ", ") }

    return verdict.baseline.isEmpty ? "no baseline yet" : "✅"
  }

  private func format(_ value: Double?) -> String {
    value.map { String(format: "%.1f", $0) } ?? "–"
  }
}
