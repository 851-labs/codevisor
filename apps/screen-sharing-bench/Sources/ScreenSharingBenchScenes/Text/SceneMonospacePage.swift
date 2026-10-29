import CoreGraphics
import CoreText

struct SceneMonospacePage {
  struct Layout {
    let width: Int
    let height: Int
    let marginX: Int
    let marginY: Int
    let scale: Int
  }

  let bitmap: SceneBitmap
  let grid: SceneGrid
  let lines: [String]

  init(_ layout: Layout, lines makeLine: (Int) -> String) throws {
    let font = SceneFonts.monospace(pixels: CGFloat(SceneGrid.fontPoints * layout.scale))
    let cellWidth = Int(Self.advance(of: font).rounded(.up))
    let cellHeight = SceneGrid.lineHeightPoints * layout.scale
    let grid = SceneGrid(
      originX: layout.marginX, originY: layout.marginY, cellWidth: cellWidth, cellHeight: cellHeight,
      columns: (layout.width - 2 * layout.marginX) / cellWidth, rows: (layout.height - 2 * layout.marginY) / cellHeight)
    self.grid = grid
    lines = (0..<grid.rows).map { _ in String(makeLine(grid.columns).prefix(grid.columns)) }
    bitmap = try SceneBitmap(.gray, width: layout.width, height: layout.height)
    bitmap.fill(CGRect(x: 0, y: 0, width: layout.width, height: layout.height), with: CGColor(gray: 1, alpha: 1))
    draw(font: font)
  }

  private func draw(font: CTFont) {
    let ink = CGColor(gray: 0, alpha: 1)
    var glyphs: [Character: CTLine] = [:]
    let baseline = (CGFloat(grid.cellHeight) + SceneFonts.ascent(of: font) - CTFontGetDescent(font).rounded(.up)) / 2
    for (row, line) in lines.enumerated() {
      for (column, character) in line.enumerated() where character != " " {
        let glyph = glyphs[character] ?? SceneFonts.line(String(character), font: font, color: ink)
        glyphs[character] = glyph
        let origin = grid.cellOrigin(column: column, row: row)
        bitmap.draw(glyph, at: CGPoint(x: CGFloat(origin.x), y: CGFloat(origin.y) + baseline.rounded()))
      }
    }
  }

  private static func advance(of font: CTFont) -> CGFloat {
    var glyph = CGGlyph(0)
    var character = UniChar(("M" as Unicode.Scalar).value)
    CTFontGetGlyphsForCharacters(font, &character, &glyph, 1)
    return CGFloat(CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, nil, 1))
  }
}
