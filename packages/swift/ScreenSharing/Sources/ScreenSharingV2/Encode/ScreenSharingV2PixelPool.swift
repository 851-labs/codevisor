import CoreVideo
import ScreenSharing

enum ScreenSharingV2PixelPool {
  static func make(width: Int, height: Int, pixelFormat: OSType) throws -> CVPixelBufferPool {
    let attributes: [CFString: Any] = [
      kCVPixelBufferPixelFormatTypeKey: pixelFormat,
      kCVPixelBufferWidthKey: width,
      kCVPixelBufferHeightKey: height,
      kCVPixelBufferMetalCompatibilityKey: true,
      kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any](),
    ]
    var pool: CVPixelBufferPool?
    let status = CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
    guard status == kCVReturnSuccess, let pool else { throw ScreenSharingError.codec("Create pixel pool", status) }

    return pool
  }

  static func buffer(from pool: CVPixelBufferPool) throws -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    let status = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
    guard status == kCVReturnSuccess, let buffer else { throw ScreenSharingError.codec("Allocate pixels", status) }

    return buffer
  }
}
