import AppKit
import SwiftUI

/// The divider grip as a REAL AppKit view that owns its strip outright:
/// hit-testing, the resize cursor, and the drag. The cursor is re-asserted
/// on every tracked mouse move — the only thing that reliably beats a
/// terminal view continuously re-asserting its I-beam next door (SwiftUI
/// onHover push/pop and descendant cursor rects both lose that race under
/// NSHostingView).
struct SplitDividerGrip: NSViewRepresentable {
    /// Branch orientation: horizontal branch → vertical divider →
    /// left/right resize; vertical branch → up/down.
    let isHorizontal: Bool
    /// Live translation along the branch axis since the drag started
    /// (SwiftUI sign convention: right/down positive).
    let onChanged: (CGFloat) -> Void
    let onEnded: () -> Void

    final class GripView: NSView {
        var isHorizontal = true
        var onChanged: ((CGFloat) -> Void)?
        var onEnded: (() -> Void)?
        private var dragStart: NSPoint?

        private var cursor: NSCursor {
            isHorizontal ? .resizeLeftRight : .resizeUpDown
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            for area in trackingAreas {
                removeTrackingArea(area)
            }
            addTrackingArea(
                NSTrackingArea(
                    rect: .zero,
                    options: [.cursorUpdate, .mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                    owner: self
                ))
        }

        override func cursorUpdate(with event: NSEvent) { cursor.set() }
        override func mouseEntered(with event: NSEvent) { cursor.set() }
        override func mouseMoved(with event: NSEvent) { cursor.set() }
        override func mouseExited(with event: NSEvent) { NSCursor.arrow.set() }

        override func mouseDown(with event: NSEvent) {
            // Screen coordinates: stable while our own layout moves under
            // the drag.
            dragStart = NSEvent.mouseLocation
        }

        override func mouseDragged(with event: NSEvent) {
            guard let dragStart else { return }
            cursor.set()
            let now = NSEvent.mouseLocation
            // Screen space is y-up; SwiftUI's translation is y-down.
            let delta = isHorizontal ? now.x - dragStart.x : dragStart.y - now.y
            onChanged?(delta)
        }

        override func mouseUp(with event: NSEvent) {
            dragStart = nil
            onEnded?()
        }
    }

    func makeNSView(context: Context) -> GripView {
        let view = GripView()
        view.isHorizontal = isHorizontal
        view.onChanged = onChanged
        view.onEnded = onEnded
        return view
    }

    func updateNSView(_ nsView: GripView, context: Context) {
        nsView.isHorizontal = isHorizontal
        nsView.onChanged = onChanged
        nsView.onEnded = onEnded
    }
}
