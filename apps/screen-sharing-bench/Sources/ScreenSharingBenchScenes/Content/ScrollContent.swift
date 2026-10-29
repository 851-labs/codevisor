import Metal

struct ScrollContent: SceneContent {
  private static let marginPoints = 40
  private static let viewportsPerDocument = 2

  let fragmentFunction = "scroll"
  private let document: any MTLTexture
  private let pixelsPerTick: Int
  private let pageDownPixels: Int

  init(_ setup: BenchSceneSetup, textures: SceneTextureFactory) throws {
    let canvas = setup.canvas
    let lineHeight = canvas.pixels(SceneGrid.lineHeightPoints)
    let rows = (canvas.pixelHeight * Self.viewportsPerDocument + lineHeight - 1) / lineHeight
    var words = SceneWords(seed: setup.seed, stream: SceneStreams.scrollText)
    var number = 0
    let text = try SceneMonospacePage(
      .init(
        width: canvas.pixelWidth, height: rows * lineHeight, marginX: canvas.pixels(Self.marginPoints), marginY: 0,
        scale: canvas.scale)
    ) { columns in
      number += 1
      return Self.numbered(number, words.line(columns: columns - Self.gutter))
    }
    document = try textures.texture(from: text.bitmap)
    pixelsPerTick = canvas.pixels(BenchSceneTiming.scrollPointsPerTick)
    pageDownPixels = canvas.pixelHeight
  }

  func uniforms(forVersion tick: Int) -> SceneUniforms {
    let pageDowns = tick / BenchSceneTiming.pageDownTicks
    let offset =
      (tick % document.height * pixelsPerTick + pageDowns % document.height * pageDownPixels) % document.height
    return SceneUniforms(offset: SIMD2(0, Int32(offset)))
  }

  func textures(forVersion version: Int) -> [any MTLTexture] {
    [document]
  }

  private static let gutter = 6

  private static func numbered(_ number: Int, _ line: String) -> String {
    let label = String(number)
    return String(repeating: " ", count: max(0, gutter - 2 - label.count)) + label + "  " + line
  }
}
