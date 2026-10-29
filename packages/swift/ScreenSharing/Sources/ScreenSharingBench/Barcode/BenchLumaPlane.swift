import CoreVideo

struct BenchLumaPlane {
  private enum Layout {
    case bgra
    case luma8
  }

  private static let bgraBytesPerPixel = 4

  let width: Int
  let height: Int
  private let base: UnsafeRawPointer
  private let bytesPerRow: Int
  private let layout: Layout

  static func withPlane<Result>(
    of pixelBuffer: CVPixelBuffer, _ body: (BenchLumaPlane) throws -> Result
  ) throws -> Result {
    let layout = try layout(of: CVPixelBufferGetPixelFormatType(pixelBuffer))
    CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
    return try body(BenchLumaPlane(pixelBuffer, layout: layout))
  }

  private init(_ pixelBuffer: CVPixelBuffer, layout: Layout) throws {
    let base: UnsafeMutableRawPointer?
    switch layout {
    case .bgra:
      base = CVPixelBufferGetBaseAddress(pixelBuffer)
      bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
    case .luma8:
      base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0)
      bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
    }
    guard let base else { throw BenchBarcodeError.pixelsUnavailable }

    self.base = UnsafeRawPointer(base)
    self.layout = layout
    width = CVPixelBufferGetWidth(pixelBuffer)
    height = CVPixelBufferGetHeight(pixelBuffer)
  }

  func require(_ barcode: BenchBarcodeLayout) throws {
    guard barcode.fits(width: width, height: height) else { throw BenchBarcodeError.layoutOutsideImage }
  }

  func meanLuma(columns: (Int, Int), rows: (Int, Int)) -> Int {
    let top = luma(x: columns.0, y: rows.0) + luma(x: columns.1, y: rows.0)
    let bottom = luma(x: columns.0, y: rows.1) + luma(x: columns.1, y: rows.1)
    return (top + bottom) / 4
  }

  private func luma(x: Int, y: Int) -> Int {
    switch layout {
    case .luma8:
      return Int(base.load(fromByteOffset: y * bytesPerRow + x, as: UInt8.self))
    case .bgra:
      let pixel = base + y * bytesPerRow + x * Self.bgraBytesPerPixel
      return Self.rec709Luma(
        blue: pixel.load(as: UInt8.self), green: pixel.load(fromByteOffset: 1, as: UInt8.self),
        red: pixel.load(fromByteOffset: 2, as: UInt8.self))
    }
  }

  private static func rec709Luma(blue: UInt8, green: UInt8, red: UInt8) -> Int {
    (54 * Int(red) + 183 * Int(green) + 19 * Int(blue)) >> 8
  }

  private static func layout(of format: OSType) throws -> Layout {
    switch format {
    case kCVPixelFormatType_32BGRA:
      return .bgra
    case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
      kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_444YpCbCr8BiPlanarFullRange:
      return .luma8
    default:
      throw BenchBarcodeError.unsupportedPixelFormat(format)
    }
  }
}
