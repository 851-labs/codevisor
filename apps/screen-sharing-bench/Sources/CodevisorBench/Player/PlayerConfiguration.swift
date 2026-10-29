import ScreenSharingBenchScenes

struct PlayerConfiguration {
  let scene: BenchScene
  let seed: UInt64
  let duration: Int
  let resolution: SceneResolutionChoice
  let display: PlayerDisplayChoice
  let inputRegion: BenchInputRegion
  let hashLog: String?
  let selfInputHz: Int
}
