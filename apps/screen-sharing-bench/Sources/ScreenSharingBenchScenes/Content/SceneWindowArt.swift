import CoreGraphics
import CoreText

enum SceneWindowArt {
  private static let titleBarPoints = 28
  private static let buttonPoints = 12
  private static let textPoints = 13
  private static let lineHeightPoints = 20
  private static let marginPoints = 20
  private static let buttonColors = [
    CGColor(srgbRed: 1.0, green: 0.37, blue: 0.34, alpha: 1), CGColor(srgbRed: 1.0, green: 0.74, blue: 0.18, alpha: 1),
    CGColor(srgbRed: 0.16, green: 0.79, blue: 0.25, alpha: 1),
  ]

  static func draw(_ setup: BenchSceneSetup) throws -> SceneBitmap {
    let scale = setup.canvas.scale
    let size = (
      width: WindowDragContent.windowPoints.width * scale, height: WindowDragContent.windowPoints.height * scale
    )
    let bitmap = try SceneBitmap(.color, width: size.width, height: size.height)
    bitmap.fill(CGRect(x: 0, y: 0, width: size.width, height: size.height), with: CGColor(gray: 0.69, alpha: 1))
    bitmap.fill(
      CGRect(x: scale, y: scale, width: size.width - 2 * scale, height: size.height - 2 * scale),
      with: CGColor(gray: 1, alpha: 1))
    drawTitleBar(on: bitmap, width: size.width, scale: scale)
    drawText(on: bitmap, setup: setup, height: size.height)
    return bitmap
  }

  private static func drawTitleBar(on bitmap: SceneBitmap, width: Int, scale: Int) {
    bitmap.fill(
      CGRect(x: scale, y: scale, width: width - 2 * scale, height: titleBarPoints * scale),
      with: CGColor(gray: 0.91, alpha: 1))
    let diameter = buttonPoints * scale
    for (index, color) in buttonColors.enumerated() {
      let x = (marginPoints / 2 + index * (buttonPoints + 8)) * scale
      let rect = CGRect(x: x, y: (titleBarPoints - buttonPoints) / 2 * scale, width: diameter, height: diameter)
      bitmap.fillEllipse(in: rect, with: color)
    }
  }

  private static func drawText(on bitmap: SceneBitmap, setup: BenchSceneSetup, height: Int) {
    let scale = setup.canvas.scale
    let font = SceneFonts.system(pixels: CGFloat(textPoints * scale))
    let ink = CGColor(gray: 0.1, alpha: 1)
    var words = SceneWords(seed: setup.seed, stream: SceneStreams.windowText)
    var baseline = (titleBarPoints + marginPoints) * scale + Int(SceneFonts.ascent(of: font))
    while baseline < height - marginPoints * scale {
      let line = SceneFonts.line(words.line(columns: 90), font: font, color: ink)
      bitmap.draw(line, at: CGPoint(x: marginPoints * scale, y: baseline))
      baseline += lineHeightPoints * scale
    }
  }
}
