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

  private static let formats = [
    Format(name: "BGRA", pixelFormat: kCVPixelFormatType_32BGRA, matrix: nil, expectation: .rgb),
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
  private static let settle = Duration.seconds(1)

  static func stages(showing picture: CVPixelBuffer) async -> [VCPLevelsStage] {
    do {
      let window = try show(picture)
      defer { window.close() }
      try await Task.sleep(for: settle)
      let filter = try await filter(for: window)
      var stages: [VCPLevelsStage] = []
      for format in formats {
        stages.append(await stage(format, filter: filter))
      }
      return stages
    } catch {
      return [VCPLevelsStage("ScreenCaptureKit capture of the picture", failed: error)]
    }
  }

  private static func stage(_ format: Format, filter: SCContentFilter) async -> VCPLevelsStage {
    let name = "ScreenCaptureKit \(format.name), sRGB"
    do {
      let configuration = SCStreamConfiguration()
      configuration.width = VCPLevelsRamp.width
      configuration.height = VCPLevelsRamp.height
      configuration.pixelFormat = format.pixelFormat
      configuration.colorSpaceName = CGColorSpace.sRGB
      if let matrix = format.matrix { configuration.colorMatrix = matrix }
      configuration.showsCursor = false
      configuration.ignoreShadowsSingleWindow = true
      let sample = try await SCScreenshotManager.captureSampleBuffer(
        contentFilter: filter, configuration: configuration)
      guard let image = CMSampleBufferGetImageBuffer(sample) else { throw BenchUsageError(message: "no image") }

      return VCPLevelsStage(
        name, values: VCPLevelsRamp.values(of: image), expecting: format.expectation, tags: VCPLevelsTags.of(image))
    } catch {
      return VCPLevelsStage(name, failed: error)
    }
  }

  private static func show(_ picture: CVPixelBuffer) throws -> NSWindow {
    guard let screen = NSScreen.main, let image = cgImage(picture) else {
      throw BenchUsageError(message: "no display or picture to show")
    }

    let scale = screen.backingScaleFactor
    let size = NSSize(width: CGFloat(VCPLevelsRamp.width) / scale, height: CGFloat(VCPLevelsRamp.height) / scale)
    let window = NSWindow(
      contentRect: NSRect(origin: NSPoint(x: screen.frame.minX + 40, y: screen.frame.minY + 40), size: size),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.hasShadow = false
    window.level = .mainMenu
    let view = NSView(frame: NSRect(origin: .zero, size: size))
    view.wantsLayer = true
    view.layer?.contents = image
    view.layer?.magnificationFilter = .nearest
    view.layer?.minificationFilter = .nearest
    window.contentView = view
    NSApplication.shared.activate()
    window.orderFrontRegardless()
    return window
  }

  private static func filter(for window: NSWindow) async throws -> SCContentFilter {
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    guard let shown = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else {
      throw BenchUsageError(message: "ScreenCaptureKit doesn't list the probe's window")
    }

    return SCContentFilter(desktopIndependentWindow: shown)
  }

  private static func cgImage(_ picture: CVPixelBuffer) -> CGImage? {
    CVPixelBufferLockBaseAddress(picture, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(picture, .readOnly) }
    let stride = CVPixelBufferGetBytesPerRow(picture)
    guard let base = CVPixelBufferGetBaseAddress(picture), let space = CGColorSpace(name: CGColorSpace.sRGB),
      let provider = CGDataProvider(data: Data(bytes: base, count: stride * VCPLevelsRamp.height) as CFData)
    else { return nil }

    return CGImage(
      width: VCPLevelsRamp.width, height: VCPLevelsRamp.height, bitsPerComponent: 8, bitsPerPixel: 32,
      bytesPerRow: stride, space: space,
      bitmapInfo: CGBitmapInfo(
        rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue),
      provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
  }
}
