import ScreenSharingBenchScenes

@MainActor
struct EncodeLabCell {
  static let settleNs: UInt64 = 500_000_000

  let plan: EncodeLabPlan
  let scene: BenchScene
  let config: EncodeLabConfig

  func run() async -> EncodeLabResult {
    var result = EncodeLabResult(scene: scene.rawValue, config: config)
    do {
      try await Task.sleep(nanoseconds: Self.settleNs)
      let setup = plan.setup(scene)
      let trace = try await EncodeLabTimedPass(
        setup: setup, config: config, ticks: plan.ticks(scene), warmUpTicks: plan.warmUpTicks
      ).run()
      let quality = try await EncodeLabQualityPass(setup: setup, trace: trace, samplesWanted: plan.qualitySamples).run()
      EncodeLabSummarizer(trace: trace).summarize(into: &result, quality: quality)
    } catch {
      result.error = String(describing: error)
    }
    return result
  }
}
