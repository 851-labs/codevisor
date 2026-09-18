import AppKit
import CodevisorTestSupport
import ScreenSharing
import Testing

@testable import ScreenSharing

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
    let aqua = try #require(NSAppearance(named: .aqua))
    surface.appearance = aqua
    let clear = surface.metal.clearColor
    // Resolve the expectation under the same appearance the surface uses, so
    // the test does not depend on the machine's light/dark setting.
    var resolved: NSColor?
    aqua.performAsCurrentDrawingAppearance { resolved = NSColor.windowBackgroundColor.usingColorSpace(.sRGB) }
    let expected = try #require(resolved, "window background resolves in sRGB")
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

/// Which pane point stands for which remote pixel, once the same aspect-fit the
/// renderer uses has left its bars. The surface is laid out explicitly before
/// anything is measured: an unlaid view has a zero-sized renderer to map through.
@MainActor
struct ScreenSharingVideoSurfaceGeometryTests {
  @Test func theRemoteDisplaySitsBetweenTheBarsAndTheEdgesMapToItsCorners() throws {
    let fixture = try GeometryFixture(size: .init(width: 640, height: 480))
    defer { fixture.close() }
    #expect(fixture.surface.metal.frame == fixture.surface.bounds, "layout hands the renderer the whole pane")
    // 1920 × 1080 fitted into 640 × 480 is 640 × 360, with 60-point bars.
    try fixture.expectPointer(at: .init(x: 320, y: 240), x: 0.5, y: 0.5)
    try fixture.expectPointer(at: .init(x: 0, y: 240), x: 0, y: 0.5)
    try fixture.expectPointer(at: .init(x: 640, y: 240), x: 1, y: 0.5)
    // AppKit's y grows upwards and the remote display's grows downwards.
    try fixture.expectPointer(at: .init(x: 320, y: 420), x: 0.5, y: 0)
    try fixture.expectPointer(at: .init(x: 320, y: 60), x: 0.5, y: 1)
  }

  @Test func aPointInTheBarsIsNoPointAtAllUnlessItIsAskedToClamp() throws {
    let fixture = try GeometryFixture(size: .init(width: 640, height: 480))
    defer { fixture.close() }
    fixture.expectNothing(at: .init(x: 320, y: 450))
    fixture.expectNothing(at: .init(x: 320, y: 30))
    fixture.expectNothing(at: .init(x: -10, y: 240))
    // Clamping is what a held button does: the drag keeps reporting the edge.
    try fixture.expectPointer(at: .init(x: 320, y: 450), x: 0.5, y: 0, clamp: true)
    try fixture.expectPointer(at: .init(x: 320, y: 30), x: 0.5, y: 1, clamp: true)
    try fixture.expectPointer(at: .init(x: -10, y: 240), x: 0, y: 0.5, clamp: true)
  }

  /// The remote display is addressed in normalized coordinates, so a Retina pane
  /// must send the same point as a 1× one even though it maps twice the pixels.
  @Test(arguments: [1.0, 2.0, 3.0] as [CGFloat])
  func theMappingIsIndependentOfTheBackingScaleFactor(scale: CGFloat) throws {
    let fixture = try GeometryFixture(size: .init(width: 640, height: 480), backingScale: scale)
    defer { fixture.close() }
    let backing = fixture.surface.metal.convertToBacking(fixture.surface.metal.bounds).size
    #expect(backing == CGSize(width: 640 * scale, height: 480 * scale), "the pane really is backed at \(scale)×")
    try fixture.expectPointer(at: .init(x: 320, y: 240), x: 0.5, y: 0.5)
    try fixture.expectPointer(at: .init(x: 160, y: 330), x: 0.25, y: 0.25)
    fixture.expectNothing(at: .init(x: 320, y: 450))
  }

  @Test(arguments: paneSizes)
  func theCentreAndTheVideoCornersHoldAtAnyPaneSize(size: CGSize) throws {
    let fixture = try GeometryFixture(size: size)
    defer { fixture.close() }
    let fit = min(size.width / 1920, size.height / 1080)
    let video = CGSize(width: 1920 * fit, height: 1080 * fit)
    let origin = CGPoint(x: (size.width - video.width) / 2, y: (size.height - video.height) / 2)
    try fixture.expectPointer(at: .init(x: size.width / 2, y: size.height / 2), x: 0.5, y: 0.5, accuracy: 1e-12)
    try fixture.expectPointer(at: .init(x: origin.x, y: size.height - origin.y), x: 0, y: 0, accuracy: 1e-12)
    try fixture.expectPointer(at: .init(x: origin.x + video.width, y: origin.y), x: 1, y: 1, accuracy: 1e-12)
    fixture.expectNothing(at: .init(x: -5, y: -5))
    try fixture.expectPointer(at: .init(x: -5, y: -5), x: 0, y: 1, clamp: true)
  }

  @Test func aSquareRemoteDisplayIsBarredLeftAndRightAsSoonAsTheRendererReportsIt() throws {
    let fixture = try GeometryFixture(size: .init(width: 640, height: 480))
    defer { fixture.close() }
    try fixture.expectPointer(at: .init(x: 80, y: 240), x: 0.125, y: 0.5)
    fixture.reportVideoSize(.init(width: 1000, height: 1000))
    // 480 × 480 centred in a 640-point pane leaves 80-point bars left and right.
    try fixture.expectPointer(at: .init(x: 320, y: 240), x: 0.5, y: 0.5)
    try fixture.expectPointer(at: .init(x: 80, y: 240), x: 0, y: 0.5)
    try fixture.expectPointer(at: .init(x: 320, y: 480), x: 0.5, y: 0)
    fixture.expectNothing(at: .init(x: 60, y: 240))
    try fixture.expectPointer(at: .init(x: 60, y: 240), x: 0, y: 0.5, clamp: true)
  }

  @Test func resizingThePaneResizesTheRendererAndRemapsTheSamePoint() throws {
    let fixture = try GeometryFixture(size: .init(width: 640, height: 480))
    defer { fixture.close() }
    try fixture.expectPointer(at: .init(x: 480, y: 240), x: 0.75, y: 0.5)
    fixture.resize(to: .init(width: 960, height: 480))
    #expect(fixture.surface.metal.frame.size == CGSize(width: 960, height: 480))
    // Wider than 16:9, so the video now fits by height: 853.33 × 480, no bars above.
    try fixture.expectPointer(at: .init(x: 480, y: 240), x: 0.5, y: 0.5)
    try fixture.expectPointer(at: .init(x: 480 - 1920 * (480.0 / 1080) / 2, y: 240), x: 0, y: 0.5, accuracy: 1e-12)
    try fixture.expectPointer(at: .init(x: 480, y: 480), x: 0.5, y: 0)
    fixture.expectNothing(at: .init(x: 20, y: 240))
  }

  /// `NSCursor` is process-wide state; these tests never suspend, so they run to
  /// completion on the main actor without another test seeing a hidden cursor.
  @Test func theLocalCursorDisappearsOverTheRemoteDisplayAndComesBackInTheBars() throws {
    let fixture = try GeometryFixture(size: .init(width: 640, height: 480))
    defer { fixture.close() }
    #expect(fixture.surface.beginInput())
    fixture.surface.cursorUpdate(with: try fixture.event(at: .init(x: 320, y: 240)))
    #expect(fixture.isRemoteCursor, "the host draws the pointer, so the local one is a 1 × 1 blank")
    fixture.surface.cursorUpdate(with: try fixture.event(at: .init(x: 320, y: 470)))
    #expect(NSCursor.current === NSCursor.arrow, "a bar is local chrome, not remote screen")
    fixture.surface.mouseEntered(with: try fixture.event(at: .init(x: 320, y: 240)))
    #expect(fixture.isRemoteCursor)
    fixture.surface.mouseExited(with: try fixture.event(at: .init(x: 700, y: 240)))
    #expect(NSCursor.current === NSCursor.arrow, "the pane hands the cursor back when it is left")
  }

  @Test func aViewOnlyPaneNeverTakesTheCursorAndEndingInputReturnsIt() throws {
    let fixture = try GeometryFixture(size: .init(width: 640, height: 480))
    defer { fixture.close() }
    fixture.surface.cursorUpdate(with: try fixture.event(at: .init(x: 320, y: 240)))
    #expect(NSCursor.current === NSCursor.arrow)
    #expect(fixture.surface.beginInput())
    fixture.surface.cursorUpdate(with: try fixture.event(at: .init(x: 320, y: 240)))
    #expect(fixture.isRemoteCursor)
    fixture.surface.endInput()
    #expect(NSCursor.current === NSCursor.arrow, "giving control back must not leave the machine cursorless")
  }
}

private let paneSizes: [CGSize] = [
  CGSize(width: 640, height: 480),
  CGSize(width: 500, height: 300),
  CGSize(width: 333, height: 257),
  CGSize(width: 1200, height: 480),
]

/// A pane in its own window, laid out, with an input surface that neither
/// installs a keyboard tap nor waits on a real clock.
@MainActor
private final class GeometryFixture {
  let window: GeometryTestWindow
  let surface: ScreenSharingVideoSurface
  let keyboard = GeometryKeyboardCapture()
  var isRemoteCursor: Bool {
    NSCursor.current !== NSCursor.arrow && NSCursor.current.image.size == CGSize(width: 1, height: 1)
  }

  init(size: CGSize, backingScale: CGFloat = 1) throws {
    _ = NSApplication.shared
    window = GeometryTestWindow(
      contentRect: .init(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.scale = backingScale
    surface = try ScreenSharingVideoSurface(mailbox: ScreenSharingFrameMailbox(), metrics: ScreenSharingMetrics())
    surface.input = ScreenSharingInputSurface(
      view: surface, notificationCenter: NotificationCenter(), keyboardCapture: keyboard,
      applicationIsActive: { true }, clock: TestClock())
    surface.frame = .init(origin: .zero, size: size)
    window.contentView?.addSubview(surface)
    layOut()
  }

  func layOut() {
    surface.needsLayout = true
    surface.layoutSubtreeIfNeeded()
  }

  func resize(to size: CGSize) {
    window.setContentSize(size)
    surface.frame = .init(origin: .zero, size: size)
    layOut()
  }

  /// The renderer's own path for telling the pane how big the remote display is.
  func reportVideoSize(_ size: CGSize) {
    surface.metal.coordinator.reportSize(size)
    layOut()
  }

  func event(at point: NSPoint) throws -> NSEvent {
    try #require(
      NSEvent.mouseEvent(
        with: .mouseMoved, location: point, modifierFlags: [], timestamp: 1, windowNumber: window.windowNumber,
        context: nil, eventNumber: 1, clickCount: 0, pressure: 0))
  }

  func expectPointer(
    at point: NSPoint, x: Double, y: Double, clamp: Bool = false, accuracy: Double = 1e-9,
    sourceLocation: SourceLocation = #_sourceLocation
  ) throws {
    let pointer = try #require(surface.pointer(try event(at: point), clamp: clamp), sourceLocation: sourceLocation)
    #expect(abs(pointer.x - x) < accuracy, sourceLocation: sourceLocation)
    #expect(abs(pointer.y - y) < accuracy, sourceLocation: sourceLocation)
  }

  func expectNothing(at point: NSPoint, sourceLocation: SourceLocation = #_sourceLocation) {
    guard let event = try? event(at: point) else {
      Issue.record("AppKit produced no event for \(point)", sourceLocation: sourceLocation)
      return
    }
    #expect(surface.pointer(event, clamp: false) == nil, sourceLocation: sourceLocation)
  }

  func close() {
    surface.stop()
    NSCursor.arrow.set()
    window.close()
  }
}

private final class GeometryTestWindow: NSWindow {
  var scale: CGFloat = 1
  override var isKeyWindow: Bool { true }
  override var backingScaleFactor: CGFloat { scale }
}

/// Stands in for the system tap: `beginInput()` must succeed without the suite
/// grabbing the developer's keyboard.
@MainActor
private final class GeometryKeyboardCapture: ScreenSharingKeyboardCapture {
  func start(handle: @escaping (CGEventType, CGEvent) -> Bool, interrupted: @escaping () -> Void) -> Bool { true }
  func stop() {}
}
