#if os(macOS)
  import AppKit

  @MainActor
  final class PopoverAnchorTrackingView: NSView {
    var onAnchorScrolled: () -> Void = {}
    private var scrollMonitor: Any?
    private var clipObservers: [NSObjectProtocol] = []

    override func hitTest(_: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      stopTracking()
      guard window != nil else { return }

      startTracking()
    }

    func scrollMovesAnchor(window eventWindow: NSWindow?, locationInWindow: NSPoint) -> Bool {
      guard let window, eventWindow === window, let scrollView = outermostScrollView else { return false }

      return scrollView.bounds.contains(scrollView.convert(locationInWindow, from: nil))
    }

    var isAnchorScrolledAway: Bool {
      !visibleRect.intersects(bounds)
    }

    func stopTracking() {
      if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
      scrollMonitor = nil
      for observer in clipObservers { NotificationCenter.default.removeObserver(observer) }
      clipObservers = []
    }

    private func startTracking() {
      scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
        self?.scrollWheelWillDispatch(event)
        return event
      }
      clipObservers = enclosingClipViews.map(observeBounds)
    }

    private func scrollWheelWillDispatch(_ event: NSEvent) {
      guard scrollMovesAnchor(window: event.window, locationInWindow: event.locationInWindow) else { return }

      onAnchorScrolled()
    }

    private func clipBoundsDidChange() {
      guard isAnchorScrolledAway else { return }

      onAnchorScrolled()
    }

    private func observeBounds(of clipView: NSClipView) -> NSObjectProtocol {
      NotificationCenter.default.addObserver(
        forName: NSView.boundsDidChangeNotification, object: clipView, queue: nil
      ) { [weak self] _ in
        MainActor.assumeIsolated { self?.clipBoundsDidChange() }
      }
    }

    private var enclosingClipViews: [NSClipView] {
      sequence(first: self as NSView, next: \.superview).compactMap { $0 as? NSClipView }
    }

    private var outermostScrollView: NSScrollView? {
      sequence(first: self as NSView, next: \.superview).compactMap { $0 as? NSScrollView }.last
    }
  }
#endif
