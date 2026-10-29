import Foundation
import ScreenSharingBench

struct ResultsMarkdown {
  let history: ResultsHistory
  let chartURL: String?
  let preflight: ResultsPreflight?

  var text: String {
    ([title, method, preflightLine, chart, ""] + table + ["", stages]).compactMap(\.self).joined(separator: "\n")
  }

  private var run: BenchRun { history.report.run }

  private var title: String {
    "## Screen sharing bench · Tier \(run.tier) · \(run.trigger)\n\n"
      + "`\(run.id)` at `\(run.gitSha.prefix(10))` on \(history.report.environment.host.name), "
      + "\(history.nightlies.count) earlier nightlies with the same method."
  }

  private var method: String? {
    run.method.map {
      "Each cell runs \($0.repetitions) time(s), interleaved with the other cells, for \($0.durationS) s with the first "
        + "\($0.warmUpS) s left out; the numbers are the median over the repetitions."
    }
  }

  private var preflightLine: String? {
    preflight.map { "C5 preflight: \($0.description)" }
  }

  private var chart: String? {
    chartURL.map { "\n![Per-stage e2e p50 and the nightly trend for each cell](\($0))" }
  }

  private var table: [String] {
    let header = [
      "| scene | network | e2e p50 ms | p50 range | outside jitter buffer | e2e p95 ms | vs nightlies | updates/s | freezes "
        + "| Mbit/s | valid |",
      "| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |",
    ]
    return header + history.summaries.map(row)
  }

  private func row(_ summary: BenchCellSummary) -> String {
    let range = summary.e2eP50MinMs.flatMap { low in summary.e2eP50MaxMs.map { "\(format(low))–\(format($0))" } }
    let cells = [
      summary.cell.scene, summary.cell.network, format(summary.e2eP50Ms), range ?? "–",
      format(summary.e2eOutsideJitterBufferP50Ms), format(summary.e2eP95Ms),
      versusBaseline(summary), format(summary.updatesPerS), summary.freezeRatio.map { format($0 * 100) + "%" } ?? "–",
      format(summary.bitrateMbps), "\(summary.valid)/\(summary.repetitions)",
    ]
    return "| " + cells.joined(separator: " | ") + " |"
  }

  private func versusBaseline(_ summary: BenchCellSummary) -> String {
    let latency = history.judgedLatency(summary)
    guard let baseline = latency.baselineMs, let p50 = latency.observedMs, baseline > 0 else { return "–" }

    let change = String(format: "%+.1f%% (of %.1f)", (p50 - baseline) / baseline * 100, baseline)
    return latency.isOutsideTheJitterBuffer ? change + " outside the jitter buffer" : change
  }

  private var stages: String {
    let split = history.summaries.contains { $0.stagesP50Ms.isSplitAtTheJitterBuffer }
    let names = BenchStageMedians().ordered(splitAtTheJitterBuffer: split).map(\.name)
    let rows = history.summaries.map { summary in
      let values = summary.stagesP50Ms.ordered(splitAtTheJitterBuffer: split).map { format($0.p50Ms) }
      return "| \(summary.cell.scene) | \(summary.cell.network) | " + values.joined(separator: " | ") + " |"
    }
    return
      ([
        "<details><summary>Stage p50s (ms, median over repetitions)</summary>", "",
        "| scene | network | " + names.joined(separator: " | ") + " |",
        "| " + Array(repeating: "---", count: names.count + 2).joined(separator: " | ") + " |",
      ]
      + rows + ["", "</details>"]).joined(separator: "\n")
  }

  private func format(_ value: Double?) -> String {
    value.map { String(format: "%.1f", $0) } ?? "–"
  }
}
