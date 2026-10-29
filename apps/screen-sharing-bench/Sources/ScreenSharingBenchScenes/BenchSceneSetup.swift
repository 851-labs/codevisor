public struct BenchSceneSetup: Sendable, Equatable, Codable {
  public let scene: BenchScene
  public let seed: UInt64
  public let canvas: BenchSceneCanvas
  public let inputRegion: BenchInputRegion

  public init(scene: BenchScene, seed: UInt64, canvas: BenchSceneCanvas, inputRegion: BenchInputRegion = .large) {
    self.scene = scene
    self.seed = seed
    self.canvas = canvas
    self.inputRegion = inputRegion
  }
}
