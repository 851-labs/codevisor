#if os(macOS)
  import CoreGraphics
  import CoreVideo

  enum ScreenSharingCaptureColorTags {
    static func tagStandardTransfer(_ pixel: CVPixelBuffer) {
      guard CVPixelBufferGetPixelFormatType(pixel) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        holdsSRGB(pixel), transfer(of: pixel) != kCVImageBufferTransferFunction_sRGB as String
      else { return }

      CVBufferSetAttachment(
        pixel, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_sRGB, .shouldPropagate)
    }

    private static func holdsSRGB(_ pixel: CVPixelBuffer) -> Bool {
      guard let space = CVBufferCopyAttachment(pixel, kCVImageBufferCGColorSpaceKey, nil),
        CFGetTypeID(space) == CGColorSpace.typeID
      else { return false }

      return (space as! CGColorSpace).name == CGColorSpace.sRGB
    }

    private static func transfer(of pixel: CVPixelBuffer) -> String? {
      CVBufferCopyAttachment(pixel, kCVImageBufferTransferFunctionKey, nil) as? String
    }
  }
#endif
