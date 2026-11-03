import CoreVideo
import ScreenSharing
import Synchronization
import VideoToolbox

final class ScreenSharingVCPPixelConverter: @unchecked Sendable {
  static let encodedPixelFormat = kCVPixelFormatType_444YpCbCr8BiPlanarFullRange

  private struct Conversion: @unchecked Sendable {
    let capture: Int64
    let target: CVPixelBuffer
  }

  private let session: VTPixelTransferSession
  private let pool: CVPixelBufferPool
  private let last = Mutex<Conversion?>(nil)

  init(width: Int, height: Int) throws {
    session = try Self.transferSession()
    pool = try Self.pool(width: width, height: height)
  }

  deinit {
    VTPixelTransferSessionInvalidate(session)
  }

  func convert(_ source: CVPixelBuffer, capture: Int64) throws -> CVPixelBuffer {
    guard CVPixelBufferGetPixelFormatType(source) != Self.encodedPixelFormat else { return source }
    if let repeated = last.withLock({ $0?.capture == capture ? $0?.target : nil }) { return repeated }

    let target = try transfer(source)
    last.withLock { $0 = Conversion(capture: capture, target: target) }
    return target
  }

  private func transfer(_ source: CVPixelBuffer) throws -> CVPixelBuffer {
    var target: CVPixelBuffer?
    let created = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &target)
    guard created == kCVReturnSuccess, let target else { throw ScreenSharingError.codec("Allocate VCP input", created) }

    let status = VTPixelTransferSessionTransferImage(session, from: source, to: target)
    guard status == noErr else { throw ScreenSharingError.codec("Convert VCP input", status) }

    return target
  }

  private static func transferSession() throws -> VTPixelTransferSession {
    var session: VTPixelTransferSession?
    let status = VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &session)
    guard status == noErr, let session else { throw ScreenSharingError.codec("Create VCP converter", status) }

    VTSessionSetProperty(
      session, key: kVTPixelTransferPropertyKey_DestinationYCbCrMatrix, value: kCVImageBufferYCbCrMatrix_ITU_R_709_2)
    return session
  }

  private static func pool(width: Int, height: Int) throws -> CVPixelBufferPool {
    let attributes: [CFString: Any] = [
      kCVPixelBufferPixelFormatTypeKey: encodedPixelFormat, kCVPixelBufferWidthKey: width,
      kCVPixelBufferHeightKey: height, kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any](),
    ]
    var pool: CVPixelBufferPool?
    let status = CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
    guard status == kCVReturnSuccess, let pool else { throw ScreenSharingError.codec("Create VCP input pool", status) }

    return pool
  }
}
