import ScreenSharingBenchScenes

enum GeneratePlan {
  case check(SceneHashLog)
  case render(BenchSceneSetup, versions: Range<Int>, pngDirectory: String?)
}
