#if canImport(AppKit)
  import AppKit

  @MainActor
  public enum TranscriptPointerTracking {
    private static var scrollingWindows: Set<ObjectIdentifier> = []
    private static var cachedHit: (window: ObjectIdentifier, location: NSPoint, timestamp: TimeInterval, view: NSView?)?

    public static func scrollDidBegin(in window: NSWindow?) {
      guard let window else { return }
      scrollingWindows.insert(ObjectIdentifier(window))
    }

    public static func scrollDidEnd(in window: NSWindow?) {
      guard let window, scrollingWindows.remove(ObjectIdentifier(window)) != nil else { return }
      cachedHit = nil
      DispatchQueue.main.async { replayPointerMove(in: window) }
    }

    static func isScrolling(in window: NSWindow?) -> Bool {
      guard let window else { return false }
      return scrollingWindows.contains(ObjectIdentifier(window))
    }

    static func hitView(at location: NSPoint, timestamp: TimeInterval, in window: NSWindow) -> NSView? {
      let id = ObjectIdentifier(window)
      if let cachedHit, cachedHit.window == id, cachedHit.location == location, cachedHit.timestamp == timestamp {
        return cachedHit.view
      }
      let view = window.contentView?.hitTest(location)
      cachedHit = (id, location, timestamp, view)
      DispatchQueue.main.async { cachedHit = nil }
      return view
    }

    static func unoccludedLocation(of event: NSEvent, in view: NSView) -> NSPoint? {
      guard let window = view.window,
        let hit = hitView(at: event.locationInWindow, timestamp: event.timestamp, in: window),
        hit === view || hit.isDescendant(of: view)
      else { return nil }
      return view.convert(event.locationInWindow, from: nil)
    }

    private static func replayPointerMove(in window: NSWindow) {
      guard window.isKeyWindow, NSEvent.pressedMouseButtons == 0 else { return }
      let location = window.mouseLocationOutsideOfEventStream
      let timestamp = ProcessInfo.processInfo.systemUptime
      guard let target = surface(containing: hitView(at: location, timestamp: timestamp, in: window)),
        let move = NSEvent.mouseEvent(
          with: .mouseMoved,
          location: location,
          modifierFlags: NSEvent.modifierFlags,
          timestamp: timestamp,
          windowNumber: window.windowNumber,
          context: nil,
          eventNumber: 0,
          clickCount: 0,
          pressure: 0
        )
      else { return }
      target.mouseMoved(with: move)
    }

    private static func surface(containing view: NSView?) -> NSView? {
      var candidate = view
      while let view = candidate {
        if view is TranscriptSurfaceTextView || view is StaticTextSurfaceView { return view }
        candidate = view.superview
      }
      return nil
    }
  }
#endif
