import Foundation
import ScreenSharingBench

enum LoopbackSummary {
  private static let stages: [(name: String, value: @Sendable (BenchStageTimings) -> BenchDistribution?)] = [
    ("capture", \.capture), ("capture queue", \.captureQueue), ("encode", \.encode),
    ("network", \.networkResidual), ("decode", \.decode), ("render queue", \.renderQueue), ("present", \.present),
  ]

  static func progress(_ outcome: LoopbackOutcome, index: Int, of total: Int) -> String {
    let result = outcome.result
    let status = result.invalidReason.map { "invalid: \($0)" } ?? "e2e \(pair(result.e2eMs)) ms"
    return "[\(index + 1)/\(total)] \(result.scene) \(result.network): \(status), "
      + "\(format(result.updatesPerS)) updates/s, quality level \(outcome.qualityLevel)"
  }

  static func markdown(_ report: BenchReport, elapsed: Duration) -> String {
    let header = "## Tier 1 loopback (\(report.run.id), \(format(Double(elapsed.components.seconds) / 60)) min)"
    return ([header, ""] + overview(report.results) + [""] + stageTable(report.results)).joined(separator: "\n")
  }

  private static func overview(_ results: [BenchResult]) -> [String] {
    let rows = results.map { result in
      let loss = result.relay.map { "\($0.media.lost + $0.media.queueOverflow)/\($0.media.packets)" } ?? "–"
      let freezes = result.freezes.map { "\($0.count) (\(format($0.ratio * 100))%)" } ?? "–"
      return row([
        result.scene, result.network, pair(result.e2eMs), format(result.updatesPerS), format(result.shownRatio),
        freezes, result.bitrateMbps.map { format($0.p50) } ?? "–", loss, result.valid ? "yes" : "no",
      ])
    }
    return [
      row(["scene", "network", "e2e p50/p95 ms", "updates/s", "shown", "freezes", "Mbit/s p50", "lost", "valid"]),
      row(Array(repeating: "---", count: 9)),
    ] + rows
  }

  private static func stageTable(_ results: [BenchResult]) -> [String] {
    let rows = results.map { result in
      row([result.scene, result.network] + stages.map { pair(result.stagesMs.flatMap($0.value)) })
    }
    return [
      row(["scene", "network"] + stages.map { "\($0.name) p50/p95" }),
      row(Array(repeating: "---", count: stages.count + 2)),
    ] + rows
  }

  private static func row(_ cells: [String]) -> String {
    "| " + cells.joined(separator: " | ") + " |"
  }

  private static func pair(_ distribution: BenchDistribution?) -> String {
    distribution.map { "\(format($0.p50))/\(format($0.p95))" } ?? "–"
  }

  private static func format(_ value: Double) -> String {
    String(format: "%.1f", value)
  }
}
