import Metal

struct TypingContent: SceneContent {
  private static let marginPoints = 40
  private static let untyped = UInt32.max

  let fragmentFunction = "typing"
  private let page: any MTLTexture
  private let cells: any MTLTexture
  private let characterCount: Int
  private let gridOrigin: SIMD2<Int32>
  private let cellSize: SIMD2<Int32>

  init(_ setup: BenchSceneSetup, textures: SceneTextureFactory) throws {
    let canvas = setup.canvas
    var words = SceneWords(seed: setup.seed, stream: SceneStreams.typingText)
    let margin = canvas.pixels(Self.marginPoints)
    let text = try SceneMonospacePage(
      .init(width: canvas.pixelWidth, height: canvas.pixelHeight, marginX: margin, marginY: margin, scale: canvas.scale)
    ) { words.line(columns: $0) }
    let order = Self.typingOrder(of: text)
    page = try textures.texture(from: text.bitmap)
    cells = try textures.cells(width: text.grid.columns, height: text.grid.rows, values: order)
    characterCount = order.count { $0 != Self.untyped }
    gridOrigin = SIMD2(Int32(text.grid.originX), Int32(text.grid.originY))
    cellSize = SIMD2(Int32(text.grid.cellWidth), Int32(text.grid.cellHeight))
  }

  func uniforms(forVersion version: Int) -> SceneUniforms {
    SceneUniforms(count: Int32(version % (characterCount + 1)), offset: gridOrigin, size: cellSize)
  }

  func textures(forVersion version: Int) -> [any MTLTexture] {
    [page, cells]
  }

  private static func typingOrder(of page: SceneMonospacePage) -> [UInt32] {
    var next: UInt32 = 0
    return page.lines.flatMap { line in
      (0..<page.grid.columns).map { column in
        guard column < line.count else { return untyped }

        defer { next += 1 }
        return next
      }
    }
  }
}
