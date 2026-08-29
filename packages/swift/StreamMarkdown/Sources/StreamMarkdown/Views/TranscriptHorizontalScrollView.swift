#if canImport(AppKit)
    import AppKit

    /// Horizontal transcript content owns only horizontal gestures. AppKit's
    /// stock `NSScrollView` consumes both axes even when vertical scrolling is
    /// disabled, which makes the surrounding transcript appear frozen whenever
    /// the pointer is over a code or diff surface.
    @MainActor
    open class TranscriptHorizontalScrollView: NSScrollView {
        private enum GestureAxis {
            case horizontal
            case vertical
        }

        private var gestureAxis: GestureAxis?

        public override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            usesPredominantAxisScrolling = true
            verticalScrollElasticity = .none
        }

        @available(*, unavailable)
        public required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        /// Returns whether this scroll view can make progress for a vertical
        /// wheel event. Horizontal-only surfaces leave this as `false`, while
        /// bounded vertical surfaces can hand the gesture to their enclosing
        /// transcript precisely when they reach either edge.
        open func shouldConsumeVerticalScroll(_ event: NSEvent) -> Bool {
            false
        }

        open override func scrollWheel(with event: NSEvent) {
            let hasGesturePhase = !event.phase.isEmpty || !event.momentumPhase.isEmpty
            if event.phase.contains(.began) || gestureAxis == nil || !hasGesturePhase {
                gestureAxis = preferredAxis(for: event)
            }

            if gestureAxis == .vertical {
                if shouldConsumeVerticalScroll(event) {
                    super.scrollWheel(with: event)
                } else if let outerScrollView = enclosingVerticalScrollView {
                    outerScrollView.scrollWheel(with: event)
                } else {
                    super.scrollWheel(with: event)
                }
            } else {
                super.scrollWheel(with: event)
            }

            if !hasGesturePhase || event.phase.contains(.ended) || event.phase.contains(.cancelled)
                || event.momentumPhase.contains(.ended) || event.momentumPhase.contains(.cancelled)
            {
                gestureAxis = nil
            }
        }

        private func preferredAxis(for event: NSEvent) -> GestureAxis {
            if event.modifierFlags.contains(.shift) { return .horizontal }
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
