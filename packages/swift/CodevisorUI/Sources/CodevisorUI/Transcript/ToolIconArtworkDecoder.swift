import CoreGraphics
import Foundation
import ImageIO

enum ToolIconArtworkDecoder {
  static func decode(_ data: Data) -> (CGImage, Bool)? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    let count = CGImageSourceGetCount(source)
    guard count > 0 else { return nil }
    let best = widestImageIndex(in: source, count: count)
    guard
      let image = CGImageSourceCreateThumbnailAtIndex(
        source,
        best,
        [
          kCGImageSourceCreateThumbnailFromImageAlways: true,
          kCGImageSourceCreateThumbnailWithTransform: true,
          kCGImageSourceThumbnailMaxPixelSize: 64,
        ] as CFDictionary
      )
    else { return nil }
    return (image, isDarkInk(image))
  }

  private static func widestImageIndex(in source: CGImageSource, count: Int) -> Int {
    var best = 0
    var bestWidth = 0
    for index in 0..<count {
      let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
      let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
      if width > bestWidth {
        best = index
        bestWidth = width
      }
    }
    return best
  }

  static func isDarkInk(_ image: CGImage) -> Bool {
    let side = 16
    guard let pixels = rasterizedPixels(from: image, side: side) else { return false }
    return hasDarkInk(pixels, side: side)
  }

  private static func rasterizedPixels(from image: CGImage, side: Int) -> [UInt8]? {
    var pixels = [UInt8](repeating: 0, count: side * side * 4)
    let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
      guard
        let context = CGContext(
          data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
      else { return false }
      context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
      return true
    }
    guard drawn else { return nil }
    return pixels
  }

  private static func hasDarkInk(_ pixels: [UInt8], side: Int) -> Bool {
    var visible = 0
    var transparent = 0
    var luminance = 0.0
    for index in stride(from: 0, to: pixels.count, by: 4) {
      let alpha = Double(pixels[index + 3]) / 255
      guard alpha > 0.5 else {
        transparent += 1
        continue
      }
      visible += 1
      let red = Double(pixels[index]) / 255 / alpha
      let green = Double(pixels[index + 1]) / 255 / alpha
      let blue = Double(pixels[index + 2]) / 255 / alpha
      luminance += 0.2126 * red + 0.7152 * green + 0.0722 * blue
    }
    guard visible > 0, transparent > side * side / 8 else { return false }
    return luminance / Double(visible) < 0.3
  }
}
