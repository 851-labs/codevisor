import CoreGraphics

enum SceneChromaPatterns {
  private typealias Pixel = (blue: UInt8, green: UInt8, red: UInt8)

  private static let red: Pixel = (0, 0, 255)
  private static let blue: Pixel = (255, 0, 0)
  private static let warmEqualLuma: Pixel = (40, 90, 200)
  private static let coolEqualLuma: Pixel = (220, 120, 40)

  static func draw(on bitmap: SceneBitmap, in area: CGRect) {
    let width = Int(area.width) / 3
    let panels = (0..<3).map { Int(area.minX) + $0 * width }
    let rows = Int(area.minY)..<Int(area.maxY)
    paint(bitmap, columns: panels[0]..<panels[0] + width, rows: rows) { _, y in y.isMultiple(of: 2) ? red : blue }
    paint(bitmap, columns: panels[1]..<panels[1] + width, rows: rows) { x, _ in x.isMultiple(of: 2) ? red : blue }
    paint(bitmap, columns: panels[2]..<panels[2] + width, rows: rows) { x, y in
      (x + y).isMultiple(of: 2) ? warmEqualLuma : coolEqualLuma
    }
  }

  private static func paint(
    _ bitmap: SceneBitmap, columns: Range<Int>, rows: Range<Int>, color: (Int, Int) -> Pixel
  ) {
    for y in rows {
      for x in columns {
        let pixel = color(x, y)
        bitmap.setPixel(x: x, y: y, blue: pixel.blue, green: pixel.green, red: pixel.red)
      }
    }
  }
}
