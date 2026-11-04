import CoreVideo
import ScreenSharing

enum TestBGRAPixels {
  static func frame(
    width: Int = 640, height: Int = 360, shades: [UInt8], timestampNs: Int64
  ) throws
    -> ScreenSharingVideoFrame
  {
    ScreenSharingVideoFrame(
      pixelBuffer: try buffer(width: width, height: height, shades: shades), timestampNs: timestampNs)
  }

  static func noise(width: Int = 640, height: Int = 360, timestampNs: Int64) throws -> ScreenSharingVideoFrame {
    let buffer = try buffer(width: width, height: height, shades: [0])
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    let base = CVPixelBufferGetBaseAddress(buffer)!
    let stride = CVPixelBufferGetBytesPerRow(buffer)
    for row in 0..<height {
      let bytes = (base + row * stride).assumingMemoryBound(to: UInt8.self)
      for column in 0..<width {
        let shade = noiseShade(row: row, column: column)
        bytes[column * 4] = shade
        bytes[column * 4 + 1] = shade
        bytes[column * 4 + 2] = shade
      }
    }
    return ScreenSharingVideoFrame(pixelBuffer: buffer, timestampNs: timestampNs)
  }

  static func noiseShade(row: Int, column: Int) -> UInt8 {
    var hash = UInt32(truncatingIfNeeded: column) &* 0x9E37_79B1 ^ UInt32(truncatingIfNeeded: row) &* 0x85EB_CA77
    hash ^= hash >> 15
    hash &*= 0x2C1B_3C6D
    hash ^= hash >> 12
    return UInt8(truncatingIfNeeded: hash)
  }

  private static func buffer(width: Int, height: Int, shades: [UInt8]) throws -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any]] as CFDictionary
    CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes, &buffer)
    guard let buffer else { throw ScreenSharingError.unavailable("No pixel buffer.") }

    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    let base = CVPixelBufferGetBaseAddress(buffer)!
    let stride = CVPixelBufferGetBytesPerRow(buffer)
    for row in 0..<height { fill(base + row * stride, pixels: width, shade: shades[row * shades.count / height]) }
    return buffer
  }

  private static func fill(_ row: UnsafeMutableRawPointer, pixels: Int, shade: UInt8) {
    let bytes = row.assumingMemoryBound(to: UInt8.self)
    for pixel in 0..<pixels {
      bytes[pixel * 4] = shade
      bytes[pixel * 4 + 1] = shade
      bytes[pixel * 4 + 2] = shade
      bytes[pixel * 4 + 3] = 255
    }
  }
}
