import AppKit
import Foundation
import Testing
@testable import ScreenSharing

/// The remote pointer drawn locally (851-2311): pure placement geometry, and
/// the surface's two behaviours — the shape as the cursor while controlling,
/// an overlay at the host's position while viewing.
@MainActor
struct ScreenSharingRemoteCursorTests {
  @Test func theHotspotLandsOnTheVideoPositionInALetterboxedSurface() throws {
    // A 200 × 100 video in a 400 × 400 surface: scale 2, 100-unit bars top and bottom.
    let frame = try #require(
      ScreenSharingVideoGeometry.cursorFrame(
        x: 50, y: 25, hotspotX: 1, hotspotY: 2, cursorWidth: 10, cursorHeight: 16, surfaceWidth: 400,
        surfaceHeight: 400, videoWidth: 200, videoHeight: 100))
    #expect(frame.x == 98 && frame.y == 146, "(50 − 1) × 2 and 100 + (25 − 2) × 2")
    #expect(frame.width == 20 && frame.height == 32)
    #expect(
      ScreenSharingVideoGeometry.cursorFrame(
        x: 0, y: 0, hotspotX: 0, hotspotY: 0, cursorWidth: 1, cursorHeight: 1, surfaceWidth: 0, surfaceHeight: 10,
        videoWidth: 1, videoHeight: 1) == nil)
  }

  @Test func shapesBecomeImagesWithTheirTransparency() throws {
    let image = try #require(ScreenSharingVideoSurface.image(RFBCursorTestShapes.corner))
    #expect(image.width == 2 && image.height == 2)
    #expect(image.alphaInfo == .premultipliedFirst)
  }

  @Test func viewingShowsTheOverlayAtTheHostsPosition() throws {
    let surface = try ScreenSharingVideoSurface(mailbox: ScreenSharingFrameMailbox(), metrics: ScreenSharingMetrics())
    defer { surface.stop() }
    surface.frame = NSRect(x: 0, y: 0, width: 960, height: 540)
    surface.layoutSubtreeIfNeeded()
    #expect(surface.remoteCursorOverlayFrame == nil, "Nothing to draw before a shape and a position.")
    surface.showRemoteCursor(.shape(RFBCursorTestShapes.corner))
    #expect(surface.remoteCursorOverlayFrame == nil, "A shape alone has nowhere to go.")
    // The default video is 1920 × 1080 in a 960 × 540 surface: scale 0.5.
    surface.showRemoteCursor(.position(RFBPoint(x: 100, y: 200)))
    let frame = try #require(surface.remoteCursorOverlayFrame)
    #expect(frame.width == 1 && frame.height == 1)
    #expect(frame.minX == 49.5, "x = (100 − hotspot 1) × 0.5")
    // 200 × 0.5 = 100 from the top; an unflipped view counts from the bottom: 540 − 100 − 1.
    #expect(frame.minY == 439)
  }

  @Test func aShapeBecomesTheControlCursorAndHidingRestoresTheBlankOne() throws {
    let surface = try ScreenSharingVideoSurface(mailbox: ScreenSharingFrameMailbox(), metrics: ScreenSharingMetrics())
    defer { surface.stop() }
    surface.frame = NSRect(x: 0, y: 0, width: 960, height: 540)
    surface.layoutSubtreeIfNeeded()
    let blank = surface.controlCursor
    #expect(blank.image.size == NSSize(width: 1, height: 1))
    surface.showRemoteCursor(.shape(RFBCursorTestShapes.corner))
    #expect(surface.controlCursor !== blank)
    #expect(surface.controlCursor.image.size == NSSize(width: 1, height: 1), "2 px at scale 0.5")
    #expect(surface.controlCursor.hotSpot == NSPoint(x: 0.5, y: 0))
    surface.showRemoteCursor(.shape(.hidden))
    #expect(surface.controlCursor === blank)
    surface.showRemoteCursor(.position(RFBPoint(x: 1, y: 1)))
    #expect(surface.remoteCursorOverlayFrame == nil, "A hidden pointer draws nothing while viewing.")
  }
}

enum RFBCursorTestShapes {
  /// 2 × 2, hotspot (1, 0): opaque white except a transparent bottom-left pixel.
  static let corner = RFBCursorShape(
    width: 2, height: 2, hotspotX: 1, hotspotY: 0,
    pixels: [255, 255, 255, 255, 255, 255, 255, 255, 0, 0, 0, 0, 255, 255, 255, 255])
}
