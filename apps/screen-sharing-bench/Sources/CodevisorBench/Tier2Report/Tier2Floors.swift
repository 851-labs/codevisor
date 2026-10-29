import ScreenSharingBench

struct Tier2Floors {
  let p50BySceneMs: [String: Double]
  let pooledMs: BenchDistribution?

  init(_ measurements: [Tier2Measurement]) {
    let floors = measurements.filter { $0.files.meta.system == .floor && $0.invalidReason == nil }
    let byScene = Dictionary(grouping: floors, by: \.files.meta.scene)
    p50BySceneMs = byScene.compactMapValues { runs in
      BenchSystemComparison.median(runs.compactMap { $0.analysis?.imageAgeMs?.p50 })
    }
    pooledMs = BenchDistribution(floors.flatMap { $0.analysis?.imageAgesMs ?? [] })
  }

  func aboveFloor(_ result: BenchResult) -> BenchResult.AboveFloor? {
    guard let p50 = result.imageAgeMs?.p50, let floor = p50BySceneMs[result.scene] else { return nil }

    return BenchResult.AboveFloor(p50: p50 - floor)
  }
}
