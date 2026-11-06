import CoreVideo

enum EncodeLabReferencePicture {
  private static let red = 0.2126
  private static let blue = 0.0722
  private static let green = 1 - red - blue

  static func make(from bgra: CVPixelBuffer, fullRange: Bool) -> EncodeLabPicture {
    let width = CVPixelBufferGetWidth(bgra)
    let height = CVPixelBufferGetHeight(bgra)
    var picture = EncodeLabPicture(width: width, height: height)
    CVPixelBufferLockBaseAddress(bgra, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(bgra, .readOnly) }
    let stride = CVPixelBufferGetBytesPerRow(bgra)
    let base = CVPixelBufferGetBaseAddress(bgra)!.assumingMemoryBound(to: UInt8.self)
    for row in 0..<height {
      for column in 0..<width {
        let pixel = base + row * stride + column * 4
        let converted = ycbcr(red: pixel[2], green: pixel[1], blue: pixel[0], fullRange: fullRange)
        let index = row * width + column
        picture.luma[index] = Float(converted.y)
        picture.blue[index] = Float(converted.cb)
        picture.red[index] = Float(converted.cr)
      }
    }
    return picture
  }

  static func ycbcr(red r: UInt8, green g: UInt8, blue b: UInt8, fullRange: Bool) -> (y: Int, cb: Int, cr: Int) {
    let (lumaScale, chromaScale, black) = fullRange ? (1.0, 1.0, 0.0) : (219.0 / 255, 224.0 / 255, 16.0)
    let (r, g, b) = (Double(r), Double(g), Double(b))
    let y = red * r + green * g + blue * b
    return (
      level(black + y * lumaScale), level(128 + (b - y) / (2 * (1 - blue)) * chromaScale),
      level(128 + (r - y) / (2 * (1 - red)) * chromaScale)
    )
  }

  private static func level(_ value: Double) -> Int {
    Int(min(255, max(0, value.rounded())))
  }
}
