import ScreenSharingBench
import ScreenSharingBenchScenes

struct LoopbackSettings: Sendable {
  let durationSeconds: Int
  let warmUpSeconds: Int
  let seed: UInt64
  let resolution: BenchSceneResolution
  let endpoint: BenchEndpoint
  let source: LoopbackSourceKind
  let display: PlayerDisplayChoice

  var canvas: BenchSceneCanvas { BenchSceneCanvas(resolution) }
}
