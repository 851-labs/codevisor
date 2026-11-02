import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import ScreenSharingBench
import UniformTypeIdentifiers

enum StillImage {
  private static let rgbaBytesPerPixel = 4
  private static var sRGB: CGColorSpace { CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB() }

  static func write(_ buffer: CVPixelBuffer, to url: URL) throws {
    let image = try cgImage(of: buffer)
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { throw StillError.unwritable(url.path) }

    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw StillError.unwritable(url.path) }
  }

  static func read(_ url: URL) throws -> BenchRGBImage {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { throw StillError.unreadable(url.path) }

    return try rgb(of: image, path: url.path)
  }

  private static func cgImage(of buffer: CVPixelBuffer) throws -> CGImage {
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    let width = CVPixelBufferGetWidth(buffer)
    let height = CVPixelBufferGetHeight(buffer)
    let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
    guard let base = CVPixelBufferGetBaseAddress(buffer),
      let provider = CGDataProvider(data: Data(bytes: base, count: bytesPerRow * height) as CFData),
      let image = CGImage(
        width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow, space: sRGB,
        bitmapInfo: CGBitmapInfo(
          rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    else { throw StillError.unwritable("a \(width)x\(height) frame") }

    return image
  }

  private static func rgb(of image: CGImage, path: String) throws -> BenchRGBImage {
    let width = image.width
    let height = image.height
    var rgba = [UInt8](repeating: 0, count: width * height * rgbaBytesPerPixel)
    let drawn = rgba.withUnsafeMutableBytes { bytes in
      guard
        let context = CGContext(
          data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8,
          bytesPerRow: width * rgbaBytesPerPixel, space: sRGB,
          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
      else { return false }

      context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
      return true
    }
    guard drawn else { throw StillError.unreadable(path) }

    return BenchRGBImage(width: width, height: height, pixels: rgbBytes(rgba))
  }

  private static func rgbBytes(_ rgba: [UInt8]) -> [UInt8] {
    var rgb = [UInt8]()
    rgb.reserveCapacity(rgba.count / rgbaBytesPerPixel * BenchRGBImage.channels)
    for index in stride(from: 0, to: rgba.count, by: rgbaBytesPerPixel) {
      rgb.append(contentsOf: rgba[index..<index + BenchRGBImage.channels])
    }
    return rgb
  }
}
