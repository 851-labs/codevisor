#if os(macOS)
  import CoreGraphics
  import CoreVideo
  import Testing
  @testable import ScreenSharing

  struct ScreenSharingCaptureColorTagsTests {
    private func pixel(format: OSType, space: CFString?, transfer: CFString) throws -> CVPixelBuffer {
      var buffer: CVPixelBuffer?
      CVPixelBufferCreate(nil, 64, 64, format, nil, &buffer)
      let pixel = try #require(buffer)
      if let space, let colorSpace = CGColorSpace(name: space) {
        CVBufferSetAttachment(pixel, kCVImageBufferCGColorSpaceKey, colorSpace, .shouldPropagate)
      }
      CVBufferSetAttachment(pixel, kCVImageBufferTransferFunctionKey, transfer, .shouldPropagate)
      return pixel
    }

    private func transfer(of pixel: CVPixelBuffer) -> String? {
      CVBufferCopyAttachment(pixel, kCVImageBufferTransferFunctionKey, nil) as? String
    }

    @Test func anSRGBVideoRangeCaptureTaggedBT709GetsTheSRGBTransfer() throws {
      let captured = try pixel(
        format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, space: CGColorSpace.sRGB,
        transfer: kCVImageBufferTransferFunction_ITU_R_709_2)
      ScreenSharingCaptureColorTags.tagStandardTransfer(captured)
      #expect(transfer(of: captured) == kCVImageBufferTransferFunction_sRGB as String)
    }

    @Test func otherCapturesKeepTheirTransfer() throws {
      let bt709 = kCVImageBufferTransferFunction_ITU_R_709_2 as String
      for (format, space) in [
        (kCVPixelFormatType_32BGRA, CGColorSpace.sRGB),
        (kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, CGColorSpace.itur_709),
      ] {
        let captured = try pixel(format: format, space: space, transfer: bt709 as CFString)
        ScreenSharingCaptureColorTags.tagStandardTransfer(captured)
        #expect(transfer(of: captured) == bt709)
      }
    }
  }
#endif
