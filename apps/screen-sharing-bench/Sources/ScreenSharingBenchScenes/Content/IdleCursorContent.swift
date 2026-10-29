import Metal

struct IdleCursorContent: SceneContent {
  private static let marginPoints = 40
  private static let caretPoints = (width: 2, height: 18, gap: 1)

  let fragmentFunction = "idleCursor"
  private let page: any MTLTexture
  private let caretOrigin: SIMD2<Int32>
  private let caretSize: SIMD2<Int32>

  init(_ setup: BenchSceneSetup, textures: SceneTextureFactory) throws {
    let canvas = setup.canvas
    var words = SceneWords(seed: setup.seed, stream: SceneStreams.idleCursorText)
    let margin = canvas.pixels(Self.marginPoints)
    let text = try SceneMonospacePage(
      .init(width: canvas.pixelWidth, height: canvas.pixelHeight, marginX: margin, marginY: margin, scale: canvas.scale)
    ) { words.line(columns: $0) }
    page = try textures.texture(from: text.bitmap)
    let row = text.grid.rows / 2
    let cell = text.grid.cellOrigin(column: text.lines[row].count, row: row)
    caretSize = SIMD2(Int32(canvas.pixels(Self.caretPoints.width)), Int32(canvas.pixels(Self.caretPoints.height)))
    caretOrigin = SIMD2(
      Int32(cell.x + canvas.pixels(Self.caretPoints.gap)), Int32(cell.y + (text.grid.cellHeight - Int(caretSize.y)) / 2)
    )
  }

  func uniforms(forVersion version: Int) -> SceneUniforms {
    SceneUniforms(count: version.isMultiple(of: 2) ? 1 : 0, offset: caretOrigin, size: caretSize)
  }

  func textures(forVersion version: Int) -> [any MTLTexture] {
    [page]
  }
}
