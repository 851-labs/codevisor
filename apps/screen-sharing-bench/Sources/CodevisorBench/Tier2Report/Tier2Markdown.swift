import ScreenSharingBench

struct Tier2Markdown {
  let report: BenchReport
  let floors: Tier2Floors
  let interference: [Tier2Interference]
  let measurements: [Tier2Measurement]

  var text: String {
    [
      targetTable, verdictTable, Tier2Milestone(report: report, floors: floors).text, Tier2V2Table(report.results).text,
      floorTable, interferenceTable, Tier2RunTable(measurements).text,
    ]
    .compactMap(\.self)
    .joined(separator: "\n\n") + "\n"
  }

  private var targetTable: String {
    let header = [
      "| Scene | Resolution | Network | System | Encoded px | Image age p50 ms | p95 | p50 above floor | Updates/s | "
        + "Shown | Gap p95 ms | Freezes | Host CPU % | Viewer CPU % | Mbit/s p50 | Valid reps |",
      "| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |",
    ]
    let rows = Tier2Group.all(report.results).flatMap { group in
      BenchSystem.allCases.compactMap { system in
        Tier2SystemRow(group: group, system: system, results: report.results, encoded: encoded(group, system))?.text
      }
    }
    return "### Target table (median of valid repetitions)\n\n" + (header + rows).joined(separator: "\n")
  }

  private func encoded(_ group: Tier2Group, _ system: BenchSystem) -> String? {
    measurements.first { measurement in
      let meta = measurement.files.meta
      return measurement.invalidReason == nil && meta.scene == group.scene && meta.benchSystem == system
        && meta.resolutionLabel == group.resolution && meta.networkLabel == group.network
        && measurement.encodedPixels != nil
    }?.encodedPixels
  }

  private static let verdictRule =
    "Each metric compares the medians of the valid repetitions. It is a difference when the medians differ by more "
    + "than the noise band, the wider of the two systems' min–max spreads (rule: noise band), or when each system has "
    + "at least \(BenchSystemComparison.minimumSeparatedRepetitions) valid repetitions and the gap between their "
    + "ranges is wider than the tighter system's spread (rule: no overlap), and in either case only when the medians "
    + "differ by at least \(Int(BenchSystemComparison.minimumRelativeEffect * 100))% of the larger one (otherwise: "
    + "gap under the minimum effect). Otherwise it is no difference."

  private var verdictTable: String {
    let header = [
      "| Scene | Resolution | Network | System | Metric | Apple HP reps | System reps | Noise band | Verdict | Rule |",
      "| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |",
    ]
    let rows = report.comparisons.map { comparison in
      "| \(comparison.scene) | \(comparison.resolution) | \(comparison.network) | "
        + "\((comparison.system ?? .codevisor).rawValue) | \(comparison.metric) | "
        + "\(Tier2Format.list(comparison.appleHp)) | "
        + "\(Tier2Format.list(comparison.codevisor)) | \(Tier2Format.number(comparison.noiseBandMs)) | "
        + "\(comparison.verdict.rawValue) | \(Tier2Comparisons.basis(of: comparison)) |"
    }
    return "### Verdicts\n\n\(Self.verdictRule)\n\n" + (header + rows).joined(separator: "\n")
  }

  private var floorTable: String {
    let rows = floors.p50BySceneMs.keys.sorted().map { "| \($0) | \(Tier2Format.number(floors.p50BySceneMs[$0])) |" }
    let pooled = floors.pooledMs.map { "pooled: p50 \($0.p50), p95 \($0.p95), max \($0.max), n \($0.count)" } ?? "none"
    return
      "### Null-sharing floor (C3)\n\n\(pooled)\n\n| Scene and network | p50 ms (median of reps) |\n| --- | --- |\n"
      + rows.joined(separator: "\n")
  }

  private var interferenceTable: String {
    let rows = interference.map {
      "| \($0.system) | \(Tier2Format.number($0.updatesDeltaPct)) | \(Tier2Format.number($0.hostCpuDeltaPct)) | "
        + "\(Tier2Format.number($0.bitrateDeltaPct)) |"
    }
    return "### Observer interference (C4, S5, observer on vs off, %)\n\n"
      + "| System | Updates/s Δ | Host CPU Δ | Bitrate Δ |\n| --- | --- | --- | --- |\n" + rows.joined(separator: "\n")
  }
}
