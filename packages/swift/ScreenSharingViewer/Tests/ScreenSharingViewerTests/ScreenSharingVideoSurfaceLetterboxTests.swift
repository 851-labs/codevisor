import AppKit
import CodevisorScreenSharing
import Testing

@testable import ScreenSharingViewer

/// The fill around the remote display: a native window surface by default
/// (Apple's Screen Sharing seats the screen on it rather than on black bars),
/// the pane's themed color when one is set, and always re-resolved for the
/// view's current appearance.
@MainActor
struct ScreenSharingVideoSurfaceLetterboxTests {
  private func makeSurface() throws -> ScreenSharingVideoSurface {
    try ScreenSharingVideoSurface(mailbox: ScreenSharingFrameMailbox(), metrics: ScreenSharingMetrics())
  }

  @Test func defaultsToTheNativeWindowSurfaceInsteadOfBlack() throws {
    let surface = try makeSurface()
    defer { surface.stop() }
    surface.appearance = NSAppearance(named: .aqua)
    let clear = surface.metal.clearColor
    let expected = try #require(
      NSColor.windowBackgroundColor.usingColorSpace(.sRGB), "window background resolves in sRGB")
    #expect(abs(clear.red - Double(expected.redComponent)) < 0.01)
    #expect(abs(clear.green - Double(expected.greenComponent)) < 0.01)
    #expect(abs(clear.blue - Double(expected.blueComponent)) < 0.01)
    #expect(clear.alpha == 1)
    #expect(clear.red > 0.5, "the light window surface, not near-black bars")
  }

  @Test func themedSurfaceColorReplacesIt() throws {
    let surface = try makeSurface()
    defer { surface.stop() }
    surface.setLetterboxColor(NSColor(srgbRed: 0.2, green: 0.4, blue: 0.6, alpha: 1))
    let clear = surface.metal.clearColor
    #expect(abs(clear.red - 0.2) < 0.01)
    #expect(abs(clear.green - 0.4) < 0.01)
    #expect(abs(clear.blue - 0.6) < 0.01)
    #expect(clear.alpha == 1)
  }

  @Test func aTransparentColorFallsBackToTheWindowSurface() throws {
    let surface = try makeSurface()
    defer { surface.stop() }
    surface.appearance = NSAppearance(named: .aqua)
    surface.setLetterboxColor(.clear)
    let clear = surface.metal.clearColor
    #expect(clear.alpha == 1)
    #expect(clear.red > 0.5, "the opaque Metal layer never shows a clear fill")
  }

  @Test func appearanceChangesReResolveTheColor() throws {
    let surface = try makeSurface()
    defer { surface.stop() }
    surface.appearance = NSAppearance(named: .aqua)
    let light = surface.metal.clearColor
    surface.appearance = NSAppearance(named: .darkAqua)
    let dark = surface.metal.clearColor
    #expect(light.red > dark.red)
  }
}
