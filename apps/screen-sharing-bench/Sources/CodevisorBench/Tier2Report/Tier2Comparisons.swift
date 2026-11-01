import ScreenSharingBench

enum Tier2Comparisons {
  struct Metric: Sendable {
    let name: String
    let better: BenchSystemComparison.Better
    let value: @Sendable (BenchResult) -> Double?
  }

  static let metrics = [
    Metric(name: "image_age_ms.p50", better: .lower) { $0.imageAgeMs?.p50 },
    Metric(name: "image_age_ms.p95", better: .lower) { $0.imageAgeMs?.p95 },
    Metric(name: "updates_per_s", better: .higher) { $0.updatesPerS },
    Metric(name: "cpu_pct.host.p50", better: .lower) { $0.cpuPct?.host?.p50 },
    Metric(name: "cpu_pct.viewer.p50", better: .lower) { $0.cpuPct?.viewer?.p50 },
  ]

  static func make(_ results: [BenchResult]) -> [BenchComparison] {
    let valid = results.filter(\.valid)
    return Tier2Group.all(valid).flatMap { group in
      let results = valid.filter(group.contains)
      return BenchSystem.codevisorSystems.flatMap { system in
        metrics.compactMap { compare($0, system: system, in: results, group: group) }
      }
    }
  }

  static func basis(of comparison: BenchComparison) -> String {
    guard let metric = metrics.first(where: { $0.name == comparison.metric }),
      let outcome = BenchSystemComparison.verdict(
        appleHp: comparison.appleHp, codevisor: comparison.codevisor, better: metric.better)
    else { return "–" }

    return outcome.basis?.rawValue ?? "–"
  }

  private static func compare(
    _ metric: Metric, system: BenchSystem, in results: [BenchResult], group: Tier2Group
  ) -> BenchComparison? {
    let apple = results.filter { $0.system == .appleHP }.compactMap(metric.value)
    let ours = results.filter { $0.system == system }.compactMap(metric.value)
    guard let outcome = BenchSystemComparison.verdict(appleHp: apple, codevisor: ours, better: metric.better) else {
      return nil
    }

    return BenchComparison(
      scene: group.scene, resolution: group.resolution, network: group.network, metric: metric.name, system: system,
      appleHp: apple, codevisor: ours, noiseBandMs: outcome.noiseBand, verdict: outcome.verdict)
  }
}
