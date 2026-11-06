import CoreVideo
import ScreenSharingBenchScenes

struct EncodeLabNativeComparer {
  let canvas: BenchSceneCanvas
  private let fullRange: Bool
  private let upscaler: EncodeLabPixelTransfer

  init(canvas: BenchSceneCanvas, format: OSType) throws {
    self.canvas = canvas
    fullRange = format == kCVPixelFormatType_444YpCbCr8BiPlanarFullRange
    upscaler = try EncodeLabPixelTransfer(width: canvas.pixelWidth, height: canvas.pixelHeight, format: format)
  }

  func compare(native: CVPixelBuffer, shown: CVPixelBuffer) throws -> EncodeLabNativeQuality {
    let original = EncodeLabReferencePicture.make(from: native, fullRange: fullRange)
    let upscaled = picture(try upscaler.transfer(shown))
    return EncodeLabNativeQuality(
      psnrY: EncodeLabSimilarity.psnr(original.luma, upscaled.luma),
      ssimY: try EncodeLabSimilarity.ssim(
        original.luma, upscaled.luma, width: canvas.pixelWidth, height: canvas.pixelHeight))
  }

  private func picture(_ buffer: CVPixelBuffer) -> EncodeLabPicture {
    var picture = EncodeLabPicture(width: canvas.pixelWidth, height: canvas.pixelHeight)
    picture.paste(buffer, atRow: 0)
    return picture
  }
}
