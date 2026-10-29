import CoreGraphics
import CoreText
import Metal

final class SceneBitmap {
  enum Format {
    case gray
    case color

    var pixelFormat: MTLPixelFormat {
      switch self {
      case .gray: .r8Unorm
      case .color: .bgra8Unorm
      }
    }
  }

  let format: Format
  let width: Int
  let height: Int
  private let context: CGContext

  init(_ format: Format, width: Int, height: Int) throws {
    guard let context = Self.context(format, width: width, height: height) else {
      throw BenchSceneError.bitmapUnavailable
    }

    self.format = format
    self.width = width
    self.height = height
    self.context = context
    context.translateBy(x: 0, y: CGFloat(height))
    context.scaleBy(x: 1, y: -1)
    context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
    context.setShouldSmoothFonts(false)
    context.setAllowsFontSmoothing(false)
  }

  func fill(_ rect: CGRect, with color: CGColor) {
    context.setFillColor(color)
    context.fill(rect)
  }

  func draw(_ line: CTLine, at baseline: CGPoint) {
    context.textPosition = baseline
    CTLineDraw(line, context)
  }

  func fillEllipse(in rect: CGRect, with color: CGColor) {
    context.setFillColor(color)
    context.fillEllipse(in: rect)
  }

  func withBytes(_ body: (UnsafeRawPointer, Int) throws -> Void) throws {
    guard let data = context.data else { throw BenchSceneError.bitmapUnavailable }

    try body(UnsafeRawPointer(data), context.bytesPerRow)
  }

  func setPixel(x: Int, y: Int, blue: UInt8, green: UInt8, red: UInt8) {
    guard format == .color, let data = context.data else { return }

    let pixel = data + y * context.bytesPerRow + x * 4
    pixel.storeBytes(of: blue, as: UInt8.self)
    pixel.storeBytes(of: green, toByteOffset: 1, as: UInt8.self)
    pixel.storeBytes(of: red, toByteOffset: 2, as: UInt8.self)
    pixel.storeBytes(of: 0xFF, toByteOffset: 3, as: UInt8.self)
  }

  private static func context(_ format: Format, width: Int, height: Int) -> CGContext? {
    switch format {
    case .gray:
      CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
    case .color:
      CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    }
  }
}
