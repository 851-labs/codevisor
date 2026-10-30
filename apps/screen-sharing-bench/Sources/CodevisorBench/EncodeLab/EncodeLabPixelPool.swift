import CoreVideo

struct EncodeLabPixelPool: @unchecked Sendable {
  private let pool: CVPixelBufferPool

  init(width: Int, height: Int, format: OSType) throws {
    let attributes: [CFString: Any] = [
      kCVPixelBufferPixelFormatTypeKey: format,
      kCVPixelBufferWidthKey: width,
      kCVPixelBufferHeightKey: height,
      kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any](),
    ]
    var pool: CVPixelBufferPool?
    let status = CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
    guard status == kCVReturnSuccess, let pool else { throw EncodeLabError.transfer("pool", status) }

    self.pool = pool
  }

  func make() throws -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    let status = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
    guard status == kCVReturnSuccess, let buffer else { throw EncodeLabError.transfer("allocate", status) }

    return buffer
  }
}
