import Metal
import ScreenSharingBench

struct TestCardsContent: SceneContent {
  let fragmentFunction = "testCards"
  private let textLight: any MTLTexture
  private let textDark: any MTLTexture
  private let chroma: any MTLTexture
  private let layout: BenchTestCardLayout
  private let seed: UInt32

  init(_ setup: BenchSceneSetup, textures: SceneTextureFactory) throws {
    layout = BenchTestCardLayout(canvas: setup.canvas, barcodeHeight: BenchBarcodeLayout.standard.height)
    seed = UInt32(truncatingIfNeeded: setup.seed)
    textLight = try textures.texture(from: SceneCardArt.text(setup, dark: false, top: layout.top))
    textDark = try textures.texture(from: SceneCardArt.text(setup, dark: true, top: layout.top))
    chroma = try textures.texture(from: SceneCardArt.chroma(setup, top: layout.top))
  }

  func uniforms(forVersion version: Int) -> SceneUniforms {
    let isPhoto = BenchTestCard.shown(atVersion: version) == .photo
    return SceneUniforms(
      count: isPhoto ? 1 : 0, offset: SIMD2(Int32(layout.inset), Int32(layout.top)),
      size: SIMD2(repeating: Int32(layout.fiducialSize)), seed: seed)
  }

  func textures(forVersion version: Int) -> [any MTLTexture] {
    [texture(of: BenchTestCard.shown(atVersion: version))]
  }

  private func texture(of card: BenchTestCard) -> any MTLTexture {
    switch card {
    case .textLight, .photo: textLight
    case .textDark: textDark
    case .chroma: chroma
    }
  }
}
