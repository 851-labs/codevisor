import CoreVideo

enum ScreenSharingCaptureColorTags {
  private static let standardYCbCrFormats: Set<OSType> = [
    kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
  ]

  static func tagStandardTransfer(_ pixel: CVPixelBuffer) {
    guard standardYCbCrFormats.contains(CVPixelBufferGetPixelFormatType(pixel)) else { return }

    CVBufferSetAttachment(
      pixel, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_sRGB, .shouldPropagate)
  }
}
