import CoreGraphics
import CoreVideo
import ScreenCaptureKit
import SwiftUI
import Testing
@testable import CodevisorCoreMac

@Suite("Computer Use live preview corner radius")
struct ComputerUseCornerRadiusTrackerTests {
  /// A BGRA frame of a window with continuous corners of `radius` pixels,
  /// transparent outside it, as the shadowless single-window capture delivers.
  private func frame(
    width: Int, height: Int, radius: CGFloat, inset: CGFloat = 0, padding: CGFloat = 0
  ) throws -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
    let pixelBuffer = try #require(buffer)
    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
    let context = try #require(
      CGContext(
        data: CVPixelBufferGetBaseAddress(pixelBuffer),
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
      ))
    context.clear(CGRect(x: 0, y: 0, width: width, height: height))
    let rect = CGRect(x: 0, y: 0, width: width, height: height)
      .insetBy(dx: inset + padding, dy: inset)
    let path = RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: rect).cgPath
    context.setFillColor(CGColor(red: 0.9, green: 0.9, blue: 0.9, alpha: 1))
    context.addPath(path)
    context.fillPath()
    return pixelBuffer
  }

  @Test("Measures the window's corner radius from the frame", arguments: [0, 10, 20, 34, 52] as [CGFloat])
  func measures(radius: CGFloat) throws {
    let buffer = try frame(width: 800, height: 500, radius: radius)
    let content = try #require(computerUseWindowContent(pixelBuffer: buffer))
    #expect(abs(content.cornerRadiusFraction * 800 - radius) < 1.5)
    #expect(content.rect == CGRect(x: 0, y: 0, width: 1, height: 1))
  }

  @Test("Finds the window inside the frame's transparent padding")
  func padding() throws {
    // A 1596 px window fitted into a 1600 px frame: 2 px each side.
    let buffer = try frame(width: 1600, height: 900, radius: 34, padding: 2)
    let content = try #require(computerUseWindowContent(pixelBuffer: buffer))
    #expect(abs(content.rect.minX * 1600 - 2) < 0.1)
    #expect(abs(content.rect.width * 1600 - 1596) < 0.2)
    #expect(content.rect.minY == 0)
    #expect(content.rect.height == 1)
    #expect(abs(content.cornerRadiusFraction * 1596 - 34) < 1.5)
  }

  @Test("Can't tell from an opaque or letterboxed frame")
  func unknown() throws {
    // No transparency at all reads as a square window filling the frame.
    let opaque = computerUseWindowContent(width: 100, height: 100) { _, _ in 255 }
    #expect(opaque == ComputerUseWindowContent(rect: CGRect(x: 0, y: 0, width: 1, height: 1), cornerRadiusFraction: 0))
    // Fully transparent: no window.
    #expect(computerUseWindowContent(width: 100, height: 100) { _, _ in 0 } == nil)
    // A window that doesn't reach the frame's edges (letterboxed).
    let letterboxed = try frame(width: 800, height: 500, radius: 20, inset: 80)
    #expect(computerUseWindowContent(pixelBuffer: letterboxed) == nil)
  }

  @Test("Re-measures on size changes and periodically, reports only changes")
  func tracker() {
    func content(_ radius: CGFloat) -> ComputerUseWindowContent {
      ComputerUseWindowContent(rect: CGRect(x: 0, y: 0, width: 1, height: 1), cornerRadiusFraction: radius)
    }
    var tracker = ComputerUseCornerRadiusTracker()
    func measure(_ size: CGSize) -> Bool { tracker.shouldMeasure(size: size) }
    func record(_ measured: ComputerUseWindowContent?) -> ComputerUseWindowContent? { tracker.record(measured) }
    let size = CGSize(width: 800, height: 500)
    let resized = CGSize(width: 640, height: 400)
    #expect(measure(size))
    #expect(record(content(0.04)) == content(0.04))
    #expect(!measure(size))
    #expect(measure(resized))
    // Jitter and failed measurements don't report.
    #expect(record(content(0.0401)) == nil)
    #expect(record(nil) == nil)
    #expect(tracker.content == content(0.04))
    var skipped = 0
    while !measure(resized) { skipped += 1 }
    #expect(skipped == ComputerUseCornerRadiusTracker.remeasureInterval - 1)
    #expect(record(content(0.02)) == content(0.02))
  }

  @Test("The card follows the window's radius, with a fallback and a ceiling")
  func cardRadius() {
    let card = CGSize(width: 400, height: 250)
    #expect(ComputerUseLivePreviewLayout.cardCornerRadius(radiusFraction: 0.04, cardSize: card) == 16)
    #expect(ComputerUseLivePreviewLayout.cardCornerRadius(radiusFraction: nil, cardSize: card) == 12)
    #expect(ComputerUseLivePreviewLayout.cardCornerRadius(radiusFraction: 0, cardSize: card) == 0)
    // Never more than a quarter of the short side.
    #expect(ComputerUseLivePreviewLayout.cardCornerRadius(radiusFraction: 0.5, cardSize: card) == 62.5)
    #expect(
      ComputerUseLivePreviewLayout.cardCornerRadius(radiusFraction: nil, cardSize: CGSize(width: 40, height: 30)) == 7.5
    )
  }

  @Test("The window covers the card, trimming the frame's padding")
  func surfaceFrame() {
    let card = CGSize(width: 399, height: 225)
    let fill = CGRect(origin: .zero, size: card)
    // Nothing known yet: fill the card.
    #expect(ComputerUseLivePreviewLayout.surfaceFrame(frameSize: nil, content: nil, cardSize: card) == fill)
    // A 1596 × 900 window padded to a 1600 × 900 frame.
    let frame = CGSize(width: 1600, height: 900)
    let content = CGRect(x: 2.0 / 1600, y: 0, width: 1596.0 / 1600, height: 1)
    let surface = ComputerUseLivePreviewLayout.surfaceFrame(frameSize: frame, content: content, cardSize: card)
    #expect(abs(surface.width / surface.height - 1600.0 / 900) < 0.0001)
    #expect(surface.minX <= 0 && surface.minY <= 0)
    #expect(surface.minX + surface.width * content.minX <= 0.0001)
    #expect(surface.minX + surface.width * content.maxX >= card.width - 0.0001)
    #expect(surface.minY + surface.height * content.maxY >= card.height - 0.0001)
    // A card rounded a little off the window's aspect is still covered.
    let taller = CGSize(width: 320, height: 152)
    let window = CGSize(width: 957.9, height: 454)
    let covered = ComputerUseLivePreviewLayout.surfaceFrame(
      frameSize: CGSize(width: 960, height: 454),
      content: CGRect(x: 0, y: 0, width: window.width / 960, height: 1),
      cardSize: taller)
    #expect(covered.minX <= 0.0001 && covered.minY <= 0.0001)
    #expect(covered.minX + covered.width * window.width / 960 >= taller.width - 0.0001)
    #expect(covered.maxY >= taller.height - 0.0001)
    // Implausible content is ignored.
    let bogus = CGRect(x: 0.4, y: 0, width: 0.2, height: 1)
    let ignored = ComputerUseLivePreviewLayout.surfaceFrame(frameSize: frame, content: bogus, cardSize: card)
    #expect(ignored.maxX >= card.width - 0.0001 && ignored.maxY >= card.height - 0.0001)
  }

  @Test("Captures BGRA, whose alpha marks the window's padding and corners")
  func captureFormat() {
    let settings = ComputerUseNativePreviewSettings(size: CGSize(width: 960, height: 454), framesPerSecond: 15)
    let configuration = computerUseNativePreviewConfiguration(settings)
    #expect(configuration.pixelFormat == kCVPixelFormatType_32BGRA)
    #expect(configuration.ignoreShadowsSingleWindow)
  }
}
