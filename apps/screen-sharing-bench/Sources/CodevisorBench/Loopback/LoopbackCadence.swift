import ScreenSharingBench
import ScreenSharingBenchScenes

enum LoopbackCadence {
  private static let tickMs = 1000.0 / Double(BenchSceneTimeline.ticksPerSecond)
  private static let continuousScenes: Set<BenchScene> = [.typing, .scroll, .windowDrag, .video]

  static func of(_ scene: BenchScene) -> BenchSceneCadence {
    BenchSceneCadence(
      changeIntervalMs: changeIntervalTicks(scene.timeline) * tickMs,
      changesContinuously: continuousScenes.contains(scene))
  }

  private static func changeIntervalTicks(_ timeline: BenchSceneTimeline) -> Double {
    switch timeline {
    case .everyTick: 1
    case .everyTicks(let interval): Double(interval)
    case .typing, .inputDriven: steadyIntervalTicks(timeline)
    }
  }

  private static func steadyIntervalTicks(_ timeline: BenchSceneTimeline) -> Double {
    let second = BenchSceneTimeline.ticksPerSecond
    let changes = timeline.version(atTick: second) - timeline.version(atTick: 0)
    return Double(second) / Double(max(changes, 1))
  }
}
