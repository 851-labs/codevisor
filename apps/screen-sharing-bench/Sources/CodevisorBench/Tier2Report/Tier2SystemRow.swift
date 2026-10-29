import ScreenSharingBench

struct Tier2SystemRow {
  let group: Tier2Group
  let system: BenchSystem
  private let all: [BenchResult]
  private let encoded: String?

  init?(group: Tier2Group, system: BenchSystem, results: [BenchResult], encoded: String?) {
    all = results.filter { group.contains($0) && $0.system == system }
    guard !all.isEmpty else { return nil }

    self.group = group
    self.system = system
    self.encoded = encoded
  }

  var text: String {
    let valid = all.filter(\.valid)
    let cells = [
      median(valid) { $0.imageAgeMs?.p50 }, median(valid) { $0.imageAgeMs?.p95 },
      median(valid) { $0.imageAgeAboveFloorMs?.p50 }, median(valid) { $0.updatesPerS },
      median(valid) { $0.shownRatio }, median(valid) { $0.gapMs?.p95 },
      median(valid) { $0.freezes.map { Double($0.count) } },
      median(valid) { $0.cpuPct?.host?.p50 }, median(valid) { $0.cpuPct?.viewer?.p50 },
      median(valid) { $0.bitrateMbps?.p50 },
    ].map(Tier2Format.number)
    let label = "| \(group.scene) | \(group.resolution) | \(system.rawValue) | \(encoded ?? "–") | "
    return label + cells.joined(separator: " | ") + " | \(valid.count)/\(all.count) |"
  }

  private func median(_ results: [BenchResult], _ value: (BenchResult) -> Double?) -> Double? {
    BenchSystemComparison.median(results.compactMap(value))
  }
}
