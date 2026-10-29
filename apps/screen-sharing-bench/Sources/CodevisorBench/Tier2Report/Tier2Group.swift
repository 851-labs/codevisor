import ScreenSharingBench

struct Tier2Group: Hashable {
  let scene: String
  let resolution: String

  init(scene: String, resolution: String) {
    self.scene = scene
    self.resolution = resolution
  }

  init(_ result: BenchResult) {
    self.init(scene: result.scene, resolution: result.resolution)
  }

  func contains(_ result: BenchResult) -> Bool {
    Tier2Group(result) == self
  }

  static func all(_ results: [BenchResult]) -> [Tier2Group] {
    results.map(Tier2Group.init).reduce(into: []) { groups, group in
      if !groups.contains(group) { groups.append(group) }
    }
  }
}
