import CoreGraphics
import CoreText
import CoreVideo
import Foundation
import ImageIO
import ScreenSharing

package enum ProbeCodecPattern {
  package static func make(width: Int, height: Int, sequence: Int) throws -> CVPixelBuffer {
    var pixel: CVPixelBuffer?
    let status = CVPixelBufferCreate(
      nil, width, height, kCVPixelFormatType_32BGRA,
      [
        kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferCGImageCompatibilityKey: true,
        kCVPixelBufferCGBitmapContextCompatibilityKey: true,
      ] as CFDictionary, &pixel)
    guard status == noErr, let pixel else { throw ScreenSharingError.codec("Pattern allocation", status) }
    CVPixelBufferLockBaseAddress(pixel, [])
    defer { CVPixelBufferUnlockBaseAddress(pixel, []) }
    guard let context = context(pixel) else { throw ScreenSharingError.invalid("Pattern context unavailable.") }
    context.setFillColor(CGColor(gray: 0.06, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let font = CTFontCreateWithName("Menlo" as CFString, 14, nil)
    let colors = [
      CGColor(red: 1, green: 0.25, blue: 0.3, alpha: 1),
      CGColor(red: 0.2, green: 1, blue: 0.4, alpha: 1), CGColor(red: 0.3, green: 0.65, blue: 1, alpha: 1),
      CGColor(gray: 0.95, alpha: 1),
    ]
    for row in 0..<max(1, height / 22 - 5) {
      let text = String(
        format: "%04d  let frame = capture.next(); // RGB text, {} [] <> Il1O0 @ 60 fps", row + sequence)
      let attributes: [NSAttributedString.Key: Any] = [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): colors[row % colors.count],
      ]
      let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
      context.textPosition = CGPoint(x: 24, y: height - 30 - row * 22 + sequence % 22)
      CTLineDraw(line, context)
    }
    for x in 0..<width {
      context.setFillColor(colors[x % colors.count])
      context.fill(CGRect(x: x, y: 20, width: 1, height: 40))
    }
    context.setFillColor(colors[sequence % colors.count])
    context.fill(CGRect(x: sequence * 7 % width, y: 70, width: 80, height: 20))
    CVBufferSetAttachment(
      pixel, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
    CVBufferSetAttachment(
      pixel, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
    CVBufferSetAttachment(pixel, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
    return pixel
  }

  package static func write(_ pixel: CVPixelBuffer, to url: URL) throws {
    CVPixelBufferLockBaseAddress(pixel, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pixel, .readOnly) }
    guard CVPixelBufferGetPixelFormatType(pixel) == kCVPixelFormatType_32BGRA,
      let image = context(pixel)?.makeImage(),
      let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)
    else { throw ScreenSharingError.invalid("Cannot write pattern image.") }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw ScreenSharingError.invalid("PNG write failed.") }
  }

  package static func rgbRMSE(_ source: CVPixelBuffer, _ decoded: CVPixelBuffer) -> Double? {
    guard CVPixelBufferGetPixelFormatType(decoded) == kCVPixelFormatType_32BGRA,
      CVPixelBufferGetWidth(source) == CVPixelBufferGetWidth(decoded),
      CVPixelBufferGetHeight(source) == CVPixelBufferGetHeight(decoded)
    else { return nil }
    CVPixelBufferLockBaseAddress(source, .readOnly)
    CVPixelBufferLockBaseAddress(decoded, .readOnly)
    defer {
      CVPixelBufferUnlockBaseAddress(decoded, .readOnly)
      CVPixelBufferUnlockBaseAddress(source, .readOnly)
    }
    guard let a = CVPixelBufferGetBaseAddress(source)?.assumingMemoryBound(to: UInt8.self),
      let b = CVPixelBufferGetBaseAddress(decoded)?.assumingMemoryBound(to: UInt8.self)
    else { return nil }
    var squared = 0.0
    let width = CVPixelBufferGetWidth(source)
    let height = CVPixelBufferGetHeight(source)
    for y in 0..<height {
      for x in 0..<width {
        for channel in 0..<3 {
          let delta =
            Double(a[y * CVPixelBufferGetBytesPerRow(source) + x * 4 + channel])
            - Double(b[y * CVPixelBufferGetBytesPerRow(decoded) + x * 4 + channel])
          squared += delta * delta
        }
      }
    }
    return sqrt(squared / Double(width * height * 3))
  }

  private static func context(_ pixel: CVPixelBuffer) -> CGContext? {
    CGContext(
      data: CVPixelBufferGetBaseAddress(pixel), width: CVPixelBufferGetWidth(pixel),
      height: CVPixelBufferGetHeight(pixel), bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixel),
      space: CGColorSpace(name: CGColorSpace.itur_709)!,
      bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue)
  }
}
