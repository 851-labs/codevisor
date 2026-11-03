import ScreenSharingBench
import ScreenSharingBenchScenes
import ScreenSharingV2

struct LoopbackSettings: Sendable {
  let engine: BenchEngine
  let encoder: ScreenSharingV2EncoderKind
  let durationSeconds: Int
  let warmUpSeconds: Int
  let seed: UInt64
  let resolution: BenchSceneResolution
  let endpoint: BenchEndpoint
  let source: LoopbackSourceKind
  let display: PlayerDisplayChoice

  var canvas: BenchSceneCanvas { BenchSceneCanvas(resolution) }

  var system: BenchSystem {
    switch engine {
    case .v1: .codevisor
    case .v2: encoder == .videoProcessing ? .codevisorV2VCP : .codevisorV2
    }
  }
}
