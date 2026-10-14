import AppKit
import Foundation
import Testing
@testable import ScreenSharing

@MainActor
struct ScreenSharingRemoteCursorTests {
  @Test func theHotspotLandsOnTheVideoPositionInALetterboxedSurface() throws {
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

  @Test func aBigDesktopInASmallPaneKeepsTheCursorReadable() throws {
    let videoScale = 1300.0 / 3456
    #expect(ScreenSharingVideoGeometry.cursorScale(videoScale: videoScale, cursorHeight: 23) == 20.0 / 23)
    #expect(ScreenSharingVideoGeometry.cursorScale(videoScale: videoScale, cursorHeight: 46) == 20.0 / 46)
    #expect(ScreenSharingVideoGeometry.cursorScale(videoScale: videoScale, cursorHeight: 8) == 1)
    #expect(ScreenSharingVideoGeometry.cursorScale(videoScale: 1, cursorHeight: 16) == 1)
    #expect(ScreenSharingVideoGeometry.cursorScale(videoScale: 2, cursorHeight: 16) == 2)
    let surfaceHeight: Double = 1300.0 * 2234 / 3456
    let frame = ScreenSharingVideoGeometry.cursorFrame(
      x: 1000, y: 500, hotspotX: 4, hotspotY: 2, cursorWidth: 16, cursorHeight: 23, surfaceWidth: 1300,
      surfaceHeight: surfaceHeight, videoWidth: 3456, videoHeight: 2234)
    let placed = try #require(frame)
    let cursorScale: Double = 20.0 / 23
    let hotspotX: Double = placed.x + 4 * cursorScale
    let expectedX: Double = 1000 * videoScale
    #expect(abs(hotspotX - expectedX) < 1e-9)
    #expect(abs(placed.height - 20) < 1e-9)
  }

  @Test func shapesBecomeImagesWithTheirTransparency() throws {
    let image = try #require(ScreenSharingVideoSurface.image(RFBCursorTestShapes.corner))
    #expect(image.width == 2 && image.height == 2)
    #expect(image.alphaInfo == .premultipliedFirst)
  }

  @Test func thePointerWaitsForTheFirstVideoFrame() throws {
    let surface = try ScreenSharingVideoSurface(mailbox: ScreenSharingFrameMailbox(), metrics: ScreenSharingMetrics())
    defer { surface.stop() }
    surface.frame = NSRect(x: 0, y: 0, width: 960, height: 540)
    surface.layoutSubtreeIfNeeded()
    surface.showRemoteCursor(.shape(RFBCursorTestShapes.corner))
    surface.showRemoteCursor(.position(RFBPoint(x: 100, y: 200)))
    #expect(surface.remoteCursorOverlayFrame == nil)
    surface.metal.onFrameSize?(CGSize(width: 1920, height: 1080))
    #expect(surface.remoteCursorOverlayFrame != nil)
  }

  @Test func viewingShowsTheOverlayAtTheHostsPosition() throws {
    let surface = try ScreenSharingVideoSurface(mailbox: ScreenSharingFrameMailbox(), metrics: ScreenSharingMetrics())
    defer { surface.stop() }
    surface.frame = NSRect(x: 0, y: 0, width: 960, height: 540)
    surface.layoutSubtreeIfNeeded()
    surface.metal.onFrameSize?(CGSize(width: 1920, height: 1080))
    #expect(surface.remoteCursorOverlayFrame == nil, "Nothing to draw before a shape and a position.")
    surface.showRemoteCursor(.shape(RFBCursorTestShapes.corner))
    #expect(surface.remoteCursorOverlayFrame == nil, "A shape alone has nowhere to go.")
    surface.showRemoteCursor(.position(RFBPoint(x: 100, y: 200)))
    let frame = try #require(surface.remoteCursorOverlayFrame)
    #expect(frame.width == 2 && frame.height == 2)
    #expect(frame.minX == 49, "x = 100 × 0.5 − hotspot 1 × 1")
    #expect(frame.minY == 438)
  }

  @Test func theControlCursorIsTheHostsShapeElseTheArrowUnlessTheVideoShowsThePointer() throws {
    let surface = try ScreenSharingVideoSurface(mailbox: ScreenSharingFrameMailbox(), metrics: ScreenSharingMetrics())
    defer { surface.stop() }
    surface.frame = NSRect(x: 0, y: 0, width: 960, height: 540)
    surface.layoutSubtreeIfNeeded()
    surface.metal.onFrameSize?(CGSize(width: 1920, height: 1080))
    #expect(surface.controlCursor.image.size == NSSize(width: 1, height: 1), "Native: the video has the pointer.")
    surface.showRemoteCursor(.shape(.hidden))
    #expect(surface.controlCursor.image.size == NSSize(width: 1, height: 1))
    surface.setVideoShowsPointer(false)
    #expect(surface.controlCursor === NSCursor.arrow, "VNC, no cursor reported (macOS): the arrow.")
    surface.showRemoteCursor(.shape(RFBCursorTestShapes.corner))
    #expect(surface.controlCursor !== NSCursor.arrow)
    #expect(surface.controlCursor.image.size == NSSize(width: 2, height: 2), "2 px, not shrunk below 1 pt/px")
    #expect(surface.controlCursor.hotSpot == NSPoint(x: 1, y: 0))
    surface.showRemoteCursor(.shape(.hidden))
    #expect(surface.controlCursor === NSCursor.arrow, "A hidden host cursor: the arrow.")
    surface.showRemoteCursor(.position(RFBPoint(x: 1, y: 1)))
    #expect(surface.remoteCursorOverlayFrame == nil, "A hidden pointer draws nothing while viewing.")
    let transparent = RFBCursorShape(
      width: 2, height: 2, hotspotX: 0, hotspotY: 0, pixels: [UInt8](repeating: 0, count: 16))
    #expect(transparent.isInvisible && !transparent.isHidden && !RFBCursorTestShapes.corner.isInvisible)
    surface.showRemoteCursor(.shape(transparent))
    #expect(surface.controlCursor === NSCursor.arrow, "A fully transparent shape is as invisible.")
    #expect(surface.remoteCursorOverlayFrame == nil)
  }
}

extension ScreenSharingRemoteCursorTests {
  @Test func aSizedShapeIsDrawnAtItsShareOfTheDisplay() throws {
    let surface = try ScreenSharingVideoSurface(mailbox: ScreenSharingFrameMailbox(), metrics: ScreenSharingMetrics())
    defer { surface.stop() }
    surface.frame = NSRect(x: 0, y: 0, width: 1920, height: 1080)
    surface.layoutSubtreeIfNeeded()
    surface.metal.onFrameSize?(CGSize(width: 1920, height: 1080))
    let shape = RFBCursorShape(
      width: 4, height: 4, hotspotX: 2, hotspotY: 0, pixels: [UInt8](repeating: 255, count: 64))
    surface.showRemoteCursor(.sizedShape(shape, width: 0.01, height: 0.01 * 16 / 9))
    surface.showRemoteCursor(.normalizedPosition(ScreenSharingPointer(x: 0.5, y: 0.25)))
    let frame = try #require(surface.remoteCursorOverlayFrame)
    #expect(abs(frame.width - 19.2) < 1e-9)
    #expect(abs(frame.midX - 960) < 1e-6, "the hotspot is the middle of the image, on x = 0.5")
    #expect(abs((1080 - frame.maxY) - 270) < 1e-6, "the top edge on y = 0.25 (hotspot row 0)")
    #expect(abs(surface.controlCursor.image.size.width - frame.width) < 1e-9)
    surface.showRemoteCursor(.normalizedPosition(nil))
    #expect(surface.remoteCursorOverlayFrame == nil)
  }
}

enum RFBCursorTestShapes {
  static let corner = RFBCursorShape(
    width: 2, height: 2, hotspotX: 1, hotspotY: 0,
    pixels: [255, 255, 255, 255, 255, 255, 255, 255, 0, 0, 0, 0, 255, 255, 255, 255])
}
