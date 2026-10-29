import CoreGraphics
import CoreText

enum SceneCardArt {
  private static let textSizes = [9, 10, 11, 12, 13, 14, 16, 18, 20, 24]
  private static let pangram = "The quick brown fox jumps over the lazy dog 0123456789"
  private static let marginPoints = 64

  static func text(_ setup: BenchSceneSetup, dark: Bool, top: Int) throws -> SceneBitmap {
    let canvas = setup.canvas
    let bitmap = try SceneBitmap(.color, width: canvas.pixelWidth, height: canvas.pixelHeight)
    let background = dark ? CGColor(gray: 0.12, alpha: 1) : CGColor(gray: 1, alpha: 1)
    let ink = dark ? CGColor(gray: 0.9, alpha: 1) : CGColor(gray: 0, alpha: 1)
    bitmap.fill(CGRect(x: 0, y: 0, width: canvas.pixelWidth, height: canvas.pixelHeight), with: background)
    var words = SceneWords(seed: setup.seed, stream: SceneStreams.cardText)
    var baseline = top + canvas.pixels(marginPoints)
    var index = 0
    while baseline < canvas.pixelHeight - canvas.pixels(marginPoints) {
      let points = textSizes[index % textSizes.count]
      let font = SceneFonts.system(pixels: CGFloat(canvas.pixels(points)))
      let text = "\(points) pt  \(pangram)  \(words.line(columns: 60))"
      bitmap.draw(
        SceneFonts.line(text, font: font, color: ink), at: CGPoint(x: canvas.pixels(marginPoints), y: baseline))
      baseline += canvas.pixels(points * 8 / 5)
      index += 1
    }
    return bitmap
  }

  static func chroma(_ setup: BenchSceneSetup, top: Int) throws -> SceneBitmap {
    let canvas = setup.canvas
    let bitmap = try SceneBitmap(.color, width: canvas.pixelWidth, height: canvas.pixelHeight)
    bitmap.fill(
      CGRect(x: 0, y: 0, width: canvas.pixelWidth, height: canvas.pixelHeight), with: CGColor(gray: 0.5, alpha: 1))
    let margin = canvas.pixels(marginPoints)
    let area = CGRect(
      x: margin, y: top + margin, width: canvas.pixelWidth - 2 * margin, height: canvas.pixelHeight - top - 2 * margin)
    let split = area.minY + area.height * 0.55
    SceneChromaTiles.draw(
      on: bitmap, in: CGRect(x: area.minX, y: area.minY, width: area.width, height: split - area.minY),
      scale: canvas.scale)
    SceneChromaPatterns.draw(
      on: bitmap,
      in: CGRect(
        x: area.minX, y: split + CGFloat(margin) / 2, width: area.width, height: area.maxY - split - CGFloat(margin) / 2
      ))
    return bitmap
  }
}
