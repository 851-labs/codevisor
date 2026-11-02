import ScreenSharingBench

enum BenchFidelityImages {
  static let white = BenchRGB(red: 255, green: 255, blue: 255)
  static let ink = BenchRGB(red: 20, green: 20, blue: 20)
  static let paper = BenchRGB(red: 26, green: 51, blue: 204)
  static let colouredInk = BenchRGB(red: 230, green: 26, blue: 26)

  static let geometry = BenchCardGeometry(
    canvasWidth: 160, canvasHeight: 96, fiducialSize: 16,
    fiducialOrigins: [
      BenchPixelOffset(dx: 4, dy: 12), BenchPixelOffset(dx: 140, dy: 12), BenchPixelOffset(dx: 4, dy: 76),
      BenchPixelOffset(dx: 140, dy: 76),
    ],
    nonText: [
      BenchPixelRect(x: 4, y: 12, width: 16, height: 16), BenchPixelRect(x: 140, y: 12, width: 16, height: 16),
      BenchPixelRect(x: 4, y: 76, width: 16, height: 16), BenchPixelRect(x: 140, y: 76, width: 16, height: 16),
    ],
    chromaTiles: [BenchPixelRect(x: 30, y: 30, width: 100, height: 40)])

  static func textCard() -> BenchRGBImage {
    var image = filled(white)
    for row in 0..<4 {
      for x in stride(from: 30, to: 130, by: 3) {
        image.fill(BenchPixelRect(x: x, y: 34 + row * 9, width: 2, height: 5), ink)
      }
    }
    return withFiducials(image)
  }

  static func chromaCard() -> BenchRGBImage {
    var image = filled(white)
    image.fill(geometry.chromaTiles[0], paper)
    for x in stride(from: 37, to: 124, by: 4) {
      image.fill(BenchPixelRect(x: x, y: 40, width: 1, height: 20), colouredInk)
    }
    return withFiducials(image)
  }

  static func placed(_ card: BenchRGBImage, width: Int, height: Int, at offset: BenchPixelOffset) -> BenchRGBImage {
    var image = BenchRGBImage(width: width, height: height, pixels: [UInt8](repeating: 0, count: width * height * 3))
    for y in 0..<card.height {
      for x in 0..<card.width { image.setPixel(x: x + offset.dx, y: y + offset.dy, card.pixel(x: x, y: y)) }
    }
    return image
  }

  static func halved(_ card: BenchRGBImage) -> BenchRGBImage {
    var image = BenchRGBImage(
      width: card.width / 2, height: card.height / 2,
      pixels: [UInt8](repeating: 0, count: card.width / 2 * card.height / 2 * 3))
    for y in 0..<image.height {
      for x in 0..<image.width { image.setPixel(x: x, y: y, card.pixel(x: x * 2, y: y * 2)) }
    }
    return image
  }

  private static func filled(_ color: BenchRGB) -> BenchRGBImage {
    var image = BenchRGBImage(
      width: geometry.canvasWidth, height: geometry.canvasHeight,
      pixels: [UInt8](repeating: 0, count: geometry.canvasWidth * geometry.canvasHeight * 3))
    image.fill(geometry.canvas, color)
    return image
  }

  private static func withFiducials(_ card: BenchRGBImage) -> BenchRGBImage {
    var image = card
    for rect in geometry.fiducials {
      for y in 0..<rect.height {
        for x in 0..<rect.width {
          let level = UInt8(BenchFiducialTemplate.value(x: x, y: y, size: rect.width))
          image.setPixel(x: rect.x + x, y: rect.y + y, BenchRGB(red: level, green: level, blue: level))
        }
      }
    }
    return image
  }
}

extension BenchRGBImage {
  mutating func fill(_ rect: BenchPixelRect, _ color: BenchRGB) {
    for y in rect.y..<rect.maxY {
      for x in rect.x..<rect.maxX { setPixel(x: x, y: y, color) }
    }
  }
}
