import CoreVideo
import VideoToolbox

final class EncodeLabPixelTransfer: @unchecked Sendable {
  private let session: VTPixelTransferSession
  private let pool: EncodeLabPixelPool

  init(width: Int, height: Int, format: OSType) throws {
    var session: VTPixelTransferSession?
    let created = VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &session)
    guard created == noErr, let session else { throw EncodeLabError.transfer("create", created) }

    self.session = session
    pool = try EncodeLabPixelPool(width: width, height: height, format: format)
    try setMatrix()
  }

  deinit {
    VTPixelTransferSessionInvalidate(session)
  }

  func transfer(_ source: CVPixelBuffer) throws -> CVPixelBuffer {
    let target = try pool.make()
    let status = VTPixelTransferSessionTransferImage(session, from: source, to: target)
    guard status == noErr else { throw EncodeLabError.transfer("transfer", status) }

    return target
  }

  private func setMatrix() throws {
    let status = VTSessionSetProperty(
      session, key: kVTPixelTransferPropertyKey_DestinationYCbCrMatrix, value: kCVImageBufferYCbCrMatrix_ITU_R_709_2)
    guard status == noErr else { throw EncodeLabError.transfer("matrix", status) }
  }
}
