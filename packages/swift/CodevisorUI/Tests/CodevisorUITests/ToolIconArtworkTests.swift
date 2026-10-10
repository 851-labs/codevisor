import CoreGraphics
import Testing
@testable import CodevisorUI

@Suite("Tool icon artwork")
struct ToolIconArtworkTests {
  /// A 32px image: a filled disc of `ink` on transparency, or on `background`.
  private func mark(ink: CGFloat, background: CGFloat? = nil) throws -> CGImage {
    let context = try #require(
      CGContext(
        data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      ))
    if let background {
      context.setFillColor(gray: background, alpha: 1)
      context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
    }
    context.setFillColor(gray: ink, alpha: 1)
    context.fillEllipse(in: CGRect(x: 4, y: 4, width: 24, height: 24))
    return try #require(context.makeImage())
  }

  @Test("Only see-through marks with dark ink need a light plate in dark mode")
  func darkInk() throws {
    #expect(ToolIconImages.isDarkInk(try mark(ink: 0.1)))
    #expect(!ToolIconImages.isDarkInk(try mark(ink: 0.95)))
    // Opaque artwork brings its own background, however dark.
    #expect(!ToolIconImages.isDarkInk(try mark(ink: 0.1, background: 0.05)))
  }
}
