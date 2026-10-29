import ScreenSharingBenchScenes

enum SceneResolutionChoice: String, CaseIterable {
  case native
  case r1 = "R1"
  case r2 = "R2"
  case r3 = "R3"

  var fixed: BenchSceneResolution? {
    BenchSceneResolution(rawValue: rawValue)
  }
}
