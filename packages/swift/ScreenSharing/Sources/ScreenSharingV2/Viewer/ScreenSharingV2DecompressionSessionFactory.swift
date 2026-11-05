import CoreMedia
import ScreenSharing
import VideoToolbox

enum ScreenSharingV2DecompressionSessionFactory {
  static func make(format: CMVideoFormatDescription) throws -> VTDecompressionSession {
    var callback = VTDecompressionOutputCallbackRecord(
      decompressionOutputCallback: { _, context, status, _, image, _, _ in
        guard let context else { return }

        Unmanaged<ScreenSharingV2DecodeContext>.fromOpaque(context).takeRetainedValue()
          .deliver(status: status, image: image)
      }, decompressionOutputRefCon: nil)
    return try make(format: format, callback: &callback)
  }

  static func make(
    format: CMVideoFormatDescription, callback: UnsafePointer<VTDecompressionOutputCallbackRecord>?
  ) throws -> VTDecompressionSession {
    var created: VTDecompressionSession?
    let status = VTDecompressionSessionCreate(
      allocator: kCFAllocatorDefault, formatDescription: format, decoderSpecification: specification,
      imageBufferAttributes: attributes(pixelFormat: decodedPixelFormat(format)), outputCallback: callback,
      decompressionSessionOut: &created)
    guard status == noErr, let created else { throw ScreenSharingError.codec("Create hardware decoder", status) }

    VTSessionSetProperty(created, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
    return created
  }

  private static var specification: CFDictionary {
    #if targetEnvironment(simulator)
      [:] as CFDictionary
    #else
      [kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: true] as CFDictionary
    #endif
  }

  static func decodedPixelFormat(_ format: CMVideoFormatDescription) -> OSType {
    let chroma = (try? ScreenSharingHEVCFormat.read(format))?.chroma
    guard chroma == 3 else { return ScreenSharingV2Profile.decodedPixelFormat }

    return signalsFullRange(format)
      ? kCVPixelFormatType_444YpCbCr8BiPlanarFullRange : kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange
  }

  private static func signalsFullRange(_ format: CMVideoFormatDescription) -> Bool {
    CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_FullRangeVideo) as? Bool == true
  }

  private static func attributes(pixelFormat: OSType) -> CFDictionary {
    [
      kCVPixelBufferPixelFormatTypeKey: pixelFormat,
      kCVPixelBufferMetalCompatibilityKey: true,
      kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any],
    ] as CFDictionary
  }
}
