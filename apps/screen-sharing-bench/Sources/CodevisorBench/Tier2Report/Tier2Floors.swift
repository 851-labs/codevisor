import ScreenSharingBench

struct Tier2Floors {
  let p50BySceneMs: [String: Double]
  let p95BySceneMs: [String: Double]
  let pooledMs: BenchDistribution?

  init(_ measurements: [Tier2Measurement]) {
    let floors = measurements.filter { $0.files.meta.system == .floor && $0.invalidReason == nil }
    let byScene = Dictionary(grouping: floors) {
      Self.key(scene: $0.files.meta.scene, network: $0.files.meta.networkLabel)
    }
    p50BySceneMs = byScene.compactMapValues { runs in
      BenchSystemComparison.median(runs.compactMap { $0.analysis?.imageAgeMs?.p50 })
    }
    p95BySceneMs = byScene.compactMapValues { runs in
      BenchSystemComparison.median(runs.compactMap { $0.analysis?.imageAgeMs?.p95 })
    }
    let pooledNetwork = floors.map(\.files.meta.networkLabel).min()
    let pooled = floors.filter { $0.files.meta.networkLabel == pooledNetwork }
    pooledMs = BenchDistribution(pooled.flatMap { $0.analysis?.imageAgesMs ?? [] })
  }

  func aboveFloor(_ result: BenchResult) -> BenchResult.AboveFloor? {
    let key = Self.key(scene: result.scene, network: result.network)
    guard let p50 = result.imageAgeMs?.p50, let floor = p50BySceneMs[key] else { return nil }

    return BenchResult.AboveFloor(p50: p50 - floor)
  }

  func p95(scene: String, network: String) -> Double? {
    p95BySceneMs[Self.key(scene: scene, network: network)]
  }

  func p50(scene: String, network: String) -> Double? {
    p50BySceneMs[Self.key(scene: scene, network: network)]
  }

  private static func key(scene: String, network: String) -> String {
    "\(scene) \(network)"
  }
}
