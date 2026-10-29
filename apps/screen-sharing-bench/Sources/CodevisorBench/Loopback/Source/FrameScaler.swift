import CoreVideo
import VideoToolbox

final class FrameScaler: @unchecked Sendable {
  private let session: VTPixelTransferSession
  private let pool: CVPixelBufferPool

  init(width: Int, height: Int) throws {
    var session: VTPixelTransferSession?
    let created = VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &session)
    guard created == noErr, let session else { throw FrameScalerError.unavailable(created) }

    self.session = session
    pool = try Self.pool(width: width, height: height)
  }

  deinit {
    VTPixelTransferSessionInvalidate(session)
  }

  func scaled(_ source: CVPixelBuffer) throws -> CVPixelBuffer {
    var target: CVPixelBuffer?
    let made = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &target)
    guard made == kCVReturnSuccess, let target else { throw FrameScalerError.unavailable(made) }

    let transferred = VTPixelTransferSessionTransferImage(session, from: source, to: target)
    guard transferred == noErr else { throw FrameScalerError.unavailable(transferred) }

    return target
  }

  private static func pool(width: Int, height: Int) throws -> CVPixelBufferPool {
    let attributes: [CFString: Any] = [
      kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
      kCVPixelBufferWidthKey: width,
      kCVPixelBufferHeightKey: height,
      kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any](),
    ]
    var pool: CVPixelBufferPool?
    let status = CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
    guard status == kCVReturnSuccess, let pool else { throw FrameScalerError.unavailable(status) }

    return pool
  }
}

enum FrameScalerError: Error, Equatable {
  case unavailable(Int32)
}
