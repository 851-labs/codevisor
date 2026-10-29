import Metal

struct InputContent: SceneContent {
  let fragmentFunction = "input"
  private let regionOrigin: SIMD2<Int32>
  private let regionSize: SIMD2<Int32>

  init(_ setup: BenchSceneSetup) {
    let canvas = setup.canvas
    let side = canvas.pixels(setup.inputRegion.points)
    regionSize = SIMD2(Int32(side), Int32(side))
    regionOrigin = SIMD2(Int32((canvas.pixelWidth - side) / 2), Int32((canvas.pixelHeight - side) / 2))
  }

  func uniforms(forVersion version: Int) -> SceneUniforms {
    SceneUniforms(offset: regionOrigin, size: regionSize)
  }

  func textures(forVersion version: Int) -> [any MTLTexture] {
    []
  }
}
