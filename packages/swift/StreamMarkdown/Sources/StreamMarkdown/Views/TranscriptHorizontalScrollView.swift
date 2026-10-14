#if canImport(AppKit)
  import AppKit

  @MainActor
  open class TranscriptHorizontalScrollView: NSScrollView {
    private enum GestureAxis {
      case horizontal
      case vertical
    }

    private var gestureAxis: GestureAxis?
    private var routesToSelf: Bool?

    public override init(frame frameRect: NSRect) {
      super.init(frame: frameRect)
      usesPredominantAxisScrolling = true
      verticalScrollElasticity = .none
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
      fatalError("init(coder:) has not been implemented")
    }

    open func shouldConsumeVerticalScroll(_ event: NSEvent) -> Bool {
      false
    }

    open override func scrollWheel(with event: NSEvent) {
      let hasGesturePhase = !event.phase.isEmpty || !event.momentumPhase.isEmpty
      if event.phase.contains(.began) || event.phase.contains(.mayBegin) || !hasGesturePhase {
        gestureAxis = nil
        routesToSelf = nil
      }
      if gestureAxis == nil { gestureAxis = preferredAxis(for: event) }

      let toSelf: Bool
      switch gestureAxis {
      case .vertical where event.scrollingDeltaY != 0:
        toSelf = shouldConsumeVerticalScroll(event)
      case .horizontal:
        toSelf = overflowsHorizontally
      default:
        toSelf = routesToSelf ?? (overflowsHorizontally || hasVerticalScroller)
      }
      routesToSelf = toSelf
      if !toSelf, let outerScrollView = enclosingVerticalScrollView {
        outerScrollView.scrollWheel(with: event)
      } else {
        super.scrollWheel(with: event)
      }

      if !hasGesturePhase || event.phase.contains(.ended) || event.phase.contains(.cancelled)
        || event.momentumPhase.contains(.ended) || event.momentumPhase.contains(.cancelled)
      {
        gestureAxis = nil
      }
    }

    private var overflowsHorizontally: Bool {
      guard let documentView else { return false }
      let scrollableWidth = documentView.frame.width + contentInsets.left + contentInsets.right
      return scrollableWidth > contentView.bounds.width + 0.5
    }

    private func preferredAxis(for event: NSEvent) -> GestureAxis? {
      if event.modifierFlags.contains(.shift) { return .horizontal }
      guard event.scrollingDeltaX != 0 || event.scrollingDeltaY != 0 else { return nil }
      return abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) ? .vertical : .horizontal
    }

    private var enclosingVerticalScrollView: NSScrollView? {
      var ancestor = superview
      while let view = ancestor {
        if let scrollView = view as? NSScrollView, scrollView !== self,
          scrollView.hasVerticalScroller
        {
          return scrollView
        }
        ancestor = view.superview
      }
      return nil
    }
  }
#endif
