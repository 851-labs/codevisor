import ScreenSharingBenchScenes

struct EncodeLabPlan {
  static let defaultScenes: [BenchScene] = [.idleCursor, .typing, .scroll, .windowDrag, .video, .testCards]
  static let testCardTicks = 4 * 3 * BenchSceneTimeline.ticksPerSecond

  let scenes: [BenchScene]
  let configs: [EncodeLabConfig]
  let resolution: BenchSceneResolution
  let seed: UInt64
  let durationTicks: Int
  let warmUpTicks: Int
  let qualitySamples: Int
  let output: String?
  let markdown: String?

  func setup(_ scene: BenchScene) -> BenchSceneSetup {
    BenchSceneSetup(scene: scene, seed: seed, canvas: BenchSceneCanvas(resolution))
  }

  func ticks(_ scene: BenchScene) -> Int {
    guard scene == .testCards else { return durationTicks }

    return max(durationTicks, warmUpTicks + Self.testCardTicks)
  }
}
