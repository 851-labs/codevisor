import CoreGraphics

enum SceneChromaTiles {
  private static let pairs: [(ink: CGColor, paper: CGColor)] = [
    (rgb(0.90, 0.10, 0.10), rgb(0.10, 0.20, 0.80)),
    (rgb(0.10, 0.20, 0.80), rgb(0.90, 0.10, 0.10)),
    (rgb(0.10, 0.70, 0.20), rgb(0.80, 0.10, 0.70)),
    (rgb(0.95, 0.85, 0.10), rgb(0.35, 0.10, 0.50)),
    (rgb(0.10, 0.80, 0.85), rgb(0.90, 0.45, 0.10)),
    (rgb(0.80, 0.10, 0.70), rgb(0.10, 0.70, 0.20)),
  ]
  private static let columns = 3
  private static let textSizes = [12, 14, 18]
  private static let paddingPoints = 12

  static func draw(on bitmap: SceneBitmap, in area: CGRect, scale: Int) {
    let rows = (pairs.count + columns - 1) / columns
    let tile = CGSize(
      width: (area.width / CGFloat(columns)).rounded(.down), height: (area.height / CGFloat(rows)).rounded(.down))
    for (index, pair) in pairs.enumerated() {
      let origin = CGPoint(
        x: area.minX + CGFloat(index % columns) * tile.width, y: area.minY + CGFloat(index / columns) * tile.height)
      bitmap.fill(CGRect(origin: origin, size: tile), with: pair.paper)
      drawText(on: bitmap, at: origin, ink: pair.ink, scale: scale)
    }
  }

  private static func drawText(on bitmap: SceneBitmap, at origin: CGPoint, ink: CGColor, scale: Int) {
    var baseline = origin.y + CGFloat(paddingPoints * scale)
    for points in textSizes {
      let font = SceneFonts.system(pixels: CGFloat(points * scale))
      baseline += SceneFonts.ascent(of: font)
      bitmap.draw(
        SceneFonts.line("Chroma \(points) pt Rg Bb", font: font, color: ink),
        at: CGPoint(x: origin.x + CGFloat(paddingPoints * scale), y: baseline))
      baseline += CGFloat(points * scale) * 0.6
    }
  }

  private static func rgb(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> CGColor {
    CGColor(srgbRed: red, green: green, blue: blue, alpha: 1)
  }
}
