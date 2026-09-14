import CoreVideo
import VideoToolbox

/// Used only on the serial capture callback queue. The experiment releases
/// SCK's surface after a transfer into a separately bounded, IOSurface-backed pool.
final class ScreenSharingCaptureBufferCopy {
  private var transfer: VTPixelTransferSession?
  private var pool: CVPixelBufferPool?
  private var format: (width: Int, height: Int, type: OSType)?
  static let maximumBuffers = 6

  deinit {
    if let transfer { VTPixelTransferSessionInvalidate(transfer) }
  }

  func copy(_ source: CVPixelBuffer) throws -> CVPixelBuffer? {
    if transfer == nil {
      let status = VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &transfer)
      guard status == noErr else { throw ScreenSharingError.codec("Create capture transfer", status) }
    }
    let width = CVPixelBufferGetWidth(source)
    let height = CVPixelBufferGetHeight(source)
    let type = CVPixelBufferGetPixelFormatType(source)
    if format?.width != width || format?.height != height || format?.type != type {
      let attributes: [CFString: Any] = [
        kCVPixelBufferWidthKey: width, kCVPixelBufferHeightKey: height,
        kCVPixelBufferPixelFormatTypeKey: type, kCVPixelBufferIOSurfacePropertiesKey: [:],
        kCVPixelBufferMetalCompatibilityKey: true,
      ]
      var created: CVPixelBufferPool?
      let status = CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &created)
      guard status == kCVReturnSuccess else { throw ScreenSharingError.codec("Create capture copy pool", status) }
      pool = created
      format = (width, height, type)
    }
    guard let pool, let transfer else { throw ScreenSharingError.unavailable("Capture transfer is unavailable.") }
    var destination: CVPixelBuffer?
    let status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
      nil, pool,
      [kCVPixelBufferPoolAllocationThresholdKey: Self.maximumBuffers] as CFDictionary, &destination)
    if status == kCVReturnWouldExceedAllocationThreshold { return nil }
    guard status == kCVReturnSuccess, let destination else {
      throw ScreenSharingError.codec("Allocate capture copy", status)
    }
    CVBufferPropagateAttachments(source, destination)
    let copied = VTPixelTransferSessionTransferImage(transfer, from: source, to: destination)
    guard copied == noErr else { throw ScreenSharingError.codec("Copy capture surface", copied) }
    return destination
  }
}
