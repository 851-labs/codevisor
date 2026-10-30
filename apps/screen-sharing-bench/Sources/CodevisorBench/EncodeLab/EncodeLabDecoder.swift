import CoreMedia
import ScreenSharing
import Synchronization
import VideoToolbox

final class EncodeLabDecoder: @unchecked Sendable {
  private let session: VTDecompressionSession
  private let decoded = Mutex(EncodeLabDecodedImage(image: nil))

  init(format: CMFormatDescription, output: OSType) throws {
    let attributes: [CFString: Any] = [
      kCVPixelBufferPixelFormatTypeKey: output, kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any](),
    ]
    let specification: [CFString: Any] = [
      kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: true
    ]
    var created: VTDecompressionSession?
    let status = VTDecompressionSessionCreate(
      allocator: nil, formatDescription: format, decoderSpecification: specification as CFDictionary,
      imageBufferAttributes: attributes as CFDictionary, outputCallback: nil, decompressionSessionOut: &created)
    guard status == noErr, let created else { throw EncodeLabError.decoder("create", status) }

    session = created
  }

  deinit {
    VTDecompressionSessionInvalidate(session)
  }

  func decode(_ sample: CMSampleBuffer) throws -> CVPixelBuffer {
    store(nil)
    let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) {
      [self] _, _, image, _, _ in store(image)
    }
    VTDecompressionSessionWaitForAsynchronousFrames(session)
    guard status == noErr, let image = decoded.withLock({ $0.image }) else {
      throw EncodeLabError.decoder("decode", status)
    }

    return image
  }

  private func store(_ image: CVPixelBuffer?) {
    decoded.withLock { $0 = EncodeLabDecodedImage(image: image) }
  }
}
