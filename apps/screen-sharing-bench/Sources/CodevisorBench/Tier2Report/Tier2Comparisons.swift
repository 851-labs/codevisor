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
    return scenes(valid).flatMap { scene in
      metrics.compactMap { compare($0, in: valid.filter { $0.scene == scene }, scene: scene) }
    }
  }

  static func scenes(_ results: [BenchResult]) -> [String] {
    results.map(\.scene).reduce(into: []) { scenes, scene in if !scenes.contains(scene) { scenes.append(scene) } }
  }

  private static func compare(_ metric: Metric, in results: [BenchResult], scene: String) -> BenchComparison? {
    let apple = results.filter { $0.system == .appleHP }.compactMap(metric.value)
    let ours = results.filter { $0.system == .codevisor }.compactMap(metric.value)
    guard let outcome = BenchSystemComparison.verdict(appleHp: apple, codevisor: ours, better: metric.better) else {
      return nil
    }

    return BenchComparison(
      scene: scene, resolution: Tier2Result.resolution, network: Tier2Result.network, metric: metric.name,
      appleHp: apple, codevisor: ours, noiseBandMs: outcome.noiseBand, verdict: outcome.verdict)
  }
}
