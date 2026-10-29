import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum GeneratePNG {
  static func write(_ pixelBuffer: CVPixelBuffer, to path: String) throws {
    guard let image = image(of: pixelBuffer),
      let destination = CGImageDestinationCreateWithURL(
        URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { throw GenerateError.pngUnavailable(path) }

    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw GenerateError.pngUnavailable(path) }
  }

  private static func image(of pixelBuffer: CVPixelBuffer) -> CGImage? {
    CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }

    let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
    let height = CVPixelBufferGetHeight(pixelBuffer)
    guard let provider = CGDataProvider(data: Data(bytes: base, count: bytesPerRow * height) as CFData) else {
      return nil
    }

    return CGImage(
      width: CVPixelBufferGetWidth(pixelBuffer), height: height, bitsPerComponent: 8, bitsPerPixel: 32,
      bytesPerRow: bytesPerRow, space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGBitmapInfo(
        rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
      provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
  }
}
