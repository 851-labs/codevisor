import CoreGraphics
import Metal

struct WindowDragContent: SceneContent {
  static let windowPoints = (width: 800, height: 600)

  let fragmentFunction = "windowDrag"
  private let window: any MTLTexture
  private let path: SceneLissajousPath
  private let scale: Int

  init(_ setup: BenchSceneSetup, textures: SceneTextureFactory) throws {
    let canvas = setup.canvas
    window = try textures.texture(from: SceneWindowArt.draw(setup))
    path = SceneLissajousPath(
      canvasPoints: (canvas.pointWidth, canvas.pointHeight), windowPoints: Self.windowPoints,
      pointsPerSecond: BenchSceneTiming.windowDragPointsPerSecond)
    scale = canvas.scale
  }

  func uniforms(forVersion tick: Int) -> SceneUniforms {
    let origin = path.origin(atTick: tick)
    return SceneUniforms(offset: SIMD2(pixel(origin.x), pixel(origin.y)))
  }

  func textures(forVersion version: Int) -> [any MTLTexture] {
    [window]
  }

  private func pixel(_ points: Double) -> Int32 {
    Int32((points * Double(scale)).rounded())
  }
}
