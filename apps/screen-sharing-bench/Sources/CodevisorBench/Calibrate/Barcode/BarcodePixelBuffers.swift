import CoreVideo
import ScreenSharingBench

enum BarcodePixelBuffers {
  private static let background: Int32 = 0x20

  static func make(count: Int, width: Int, height: Int) throws -> [CVPixelBuffer] {
    try (0..<count).map { _ in try make(width: width, height: height) }
  }

  private static func make(width: Int, height: Int) throws -> CVPixelBuffer {
    let attributes: [CFString: Any] = [
      kCVPixelBufferMetalCompatibilityKey: true, kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any](),
    ]
    var buffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(
      nil, width, height, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &buffer)
    guard status == kCVReturnSuccess, let buffer else { throw BenchBarcodeError.pixelsUnavailable }

    try fill(buffer)
    return buffer
  }

  private static func fill(_ buffer: CVPixelBuffer) throws {
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw BenchBarcodeError.pixelsUnavailable }

    memset(base, background, CVPixelBufferGetDataSize(buffer))
  }
}
