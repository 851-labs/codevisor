import AppKit
import CoreMedia
import ScreenCaptureKit
import ScreenSharingBench

@MainActor
enum VCPLevelsCapture {
  private struct Format {
    let name: String
    let pixelFormat: OSType
    let matrix: CFString?
    let expectation: VCPLevelsExpectation
  }

  private static let bgra = Format(
    name: "BGRA", pixelFormat: kCVPixelFormatType_32BGRA, matrix: nil, expectation: .rgb)
  private static let formats = [
    bgra,
    Format(
      name: "444f, BT.709 matrix", pixelFormat: kCVPixelFormatType_444YpCbCr8BiPlanarFullRange,
      matrix: CGDisplayStream.yCbCrMatrix_ITU_R_709_2, expectation: .fullRange),
    Format(
      name: "444f, default matrix", pixelFormat: kCVPixelFormatType_444YpCbCr8BiPlanarFullRange, matrix: nil,
      expectation: .fullRange),
    Format(
      name: "420v, BT.709 matrix", pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
      matrix: CGDisplayStream.yCbCrMatrix_ITU_R_709_2, expectation: .videoRange),
  ]

  static func stages(showing picture: CVPixelBuffer, on screen: NSScreen) async -> [VCPLevelsStage] {
    do {
      let shown = VCPLevelsWindow(showing: try imageView(picture), on: screen)
      defer { shown.close() }
      try await shown.settle()
      let filter = try await shown.windowFilter()
      var stages: [VCPLevelsStage] = []
      for format in formats {
        stages.append(await stage("ScreenCaptureKit window, \(format.name), sRGB", format, filter: filter))
      }
      stages.append(await displayStage("ScreenCaptureKit display, BGRA, sRGB", of: shown, expecting: .rgb))
      return stages
    } catch {
      return [VCPLevelsStage("ScreenCaptureKit capture of the picture", failed: error)]
    }
  }

  static func displayStage(
    _ name: String, of shown: VCPLevelsWindow, expecting expectation: VCPLevelsExpectation
  ) async -> VCPLevelsStage {
    do {
      let (filter, sourceRect) = try await shown.displayFilter()
      let format = Format(name: bgra.name, pixelFormat: bgra.pixelFormat, matrix: nil, expectation: expectation)
      return await stage(name, format, filter: filter, sourceRect: sourceRect)
    } catch {
      return VCPLevelsStage(name, failed: error)
    }
  }

  private static func stage(
    _ name: String, _ format: Format, filter: SCContentFilter, sourceRect: CGRect? = nil
  ) async -> VCPLevelsStage {
    do {
      let image = try await capture(format, filter: filter, sourceRect: sourceRect)
      return VCPLevelsStage(
        name, values: VCPLevelsRamp.values(of: image), expecting: format.expectation, tags: VCPLevelsTags.of(image))
    } catch {
      return VCPLevelsStage(name, failed: error)
    }
  }

  private static func capture(
    _ format: Format, filter: SCContentFilter, sourceRect: CGRect?
  ) async throws -> CVPixelBuffer {
    let configuration = SCStreamConfiguration()
    configuration.width = VCPLevelsRamp.width
    configuration.height = VCPLevelsRamp.height
    configuration.pixelFormat = format.pixelFormat
    configuration.colorSpaceName = CGColorSpace.sRGB
    if let matrix = format.matrix { configuration.colorMatrix = matrix }
    if let sourceRect { configuration.sourceRect = sourceRect }
    configuration.showsCursor = false
    configuration.ignoreShadowsSingleWindow = true
    let sample = try await SCScreenshotManager.captureSampleBuffer(contentFilter: filter, configuration: configuration)
    guard let image = CMSampleBufferGetImageBuffer(sample) else { throw BenchUsageError(message: "no image") }

    return image
  }

  private static func imageView(_ picture: CVPixelBuffer) throws -> NSView {
    guard let image = cgImage(picture) else { throw BenchUsageError(message: "the picture can't be shown") }

    let layer = CALayer()
    layer.contents = image
    layer.magnificationFilter = .nearest
    layer.minificationFilter = .nearest
    let view = NSView()
    view.layer = layer
    view.wantsLayer = true
    return view
  }

  private static func cgImage(_ picture: CVPixelBuffer) -> CGImage? {
    CVPixelBufferLockBaseAddress(picture, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(picture, .readOnly) }
    let stride = CVPixelBufferGetBytesPerRow(picture)
    guard let base = CVPixelBufferGetBaseAddress(picture), let space = CGColorSpace(name: CGColorSpace.sRGB),
      let provider = CGDataProvider(data: Data(bytes: base, count: stride * VCPLevelsRamp.height) as CFData)
    else { return nil }

    let info = CGBitmapInfo(
      rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue)
    return CGImage(
      width: VCPLevelsRamp.width, height: VCPLevelsRamp.height, bitsPerComponent: 8, bitsPerPixel: 32,
      bytesPerRow: stride, space: space, bitmapInfo: info, provider: provider, decode: nil, shouldInterpolate: false,
      intent: .defaultIntent)
  }
}
