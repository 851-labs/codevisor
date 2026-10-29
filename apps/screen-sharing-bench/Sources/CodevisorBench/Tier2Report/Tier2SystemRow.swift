import ScreenSharingBench

struct Tier2SystemRow {
  let scene: String
  let system: BenchSystem
  let results: [BenchResult]

  var text: String {
    let all = results.filter { $0.scene == scene && $0.system == system }
    let valid = all.filter(\.valid)
    let cells = [
      median(valid) { $0.imageAgeMs?.p50 }, median(valid) { $0.imageAgeMs?.p95 },
      median(valid) { $0.imageAgeAboveFloorMs?.p50 }, median(valid) { $0.updatesPerS },
      median(valid) { $0.shownRatio }, median(valid) { $0.gapMs?.p95 },
      median(valid) { $0.freezes.map { Double($0.count) } },
      median(valid) { $0.cpuPct?.host?.p50 }, median(valid) { $0.cpuPct?.viewer?.p50 },
      median(valid) { $0.bitrateMbps?.p50 },
    ].map(Tier2Format.number)
    return "| \(scene) | \(system.rawValue) | " + cells.joined(separator: " | ") + " | \(valid.count)/\(all.count) |"
  }

  private func median(_ results: [BenchResult], _ value: (BenchResult) -> Double?) -> Double? {
    BenchSystemComparison.median(results.compactMap(value))
  }
}
