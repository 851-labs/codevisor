#if canImport(AppKit)
  import AppKit
  import Testing

  @testable import StreamMarkdown

  @MainActor
  @Suite("Transcript pointer tracking")
  struct TranscriptPointerTrackingTests {
    private final class CountingView: NSView {
      var hitTests = 0

      override func hitTest(_ point: NSPoint) -> NSView? {
        hitTests += 1
        return super.hitTest(point)
      }
    }

    private func window(content: NSView) -> NSWindow {
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [], backing: .buffered, defer: true)
      window.contentView = content
      return window
    }

    @Test("Scrolling is tracked per window")
    func scrollingIsTrackedPerWindow() {
      let scrolling = window(content: NSView())
      let other = window(content: NSView())

      TranscriptPointerTracking.scrollDidBegin(in: scrolling)
      #expect(TranscriptPointerTracking.isScrolling(in: scrolling))
      #expect(!TranscriptPointerTracking.isScrolling(in: other))

      TranscriptPointerTracking.scrollDidEnd(in: scrolling)
      #expect(!TranscriptPointerTracking.isScrolling(in: scrolling))
    }

    @Test("Surfaces handling the same pointer event share one window hit test")
    func hitTestIsSharedForOnePointerEvent() {
      let content = CountingView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
      let window = window(content: content)
      let point = NSPoint(x: 40, y: 40)

      _ = TranscriptPointerTracking.hitView(at: point, timestamp: 10, in: window)
      _ = TranscriptPointerTracking.hitView(at: point, timestamp: 10, in: window)
      #expect(content.hitTests == 1)

      _ = TranscriptPointerTracking.hitView(at: point, timestamp: 11, in: window)
      #expect(content.hitTests == 2)
    }

    @Test("A point covered by another view is not reported as the surface's location")
    func occludedPointHasNoLocation() throws {
      let content = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
      let surface = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
      let overlay = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 200))
      content.addSubview(surface)
      content.addSubview(overlay)
      let window = window(content: content)
      func event(at point: NSPoint) throws -> NSEvent {
        try #require(
          NSEvent.mouseEvent(
            with: .mouseMoved, location: point, modifierFlags: [], timestamp: point.x,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
      }

      #expect(
        TranscriptPointerTracking.unoccludedLocation(of: try event(at: NSPoint(x: 50, y: 50)), in: surface) == nil)
      #expect(
        TranscriptPointerTracking.unoccludedLocation(of: try event(at: NSPoint(x: 200, y: 50)), in: surface)
          == NSPoint(x: 200, y: 50))
    }
  }
#endif
