import SwiftUI
import AppKit

/// Suspends `.hoverTracking` for a subtree. The transcript sets this while a
/// stream is being followed: following means real scrolling every frame, and
/// every scroll tick makes AppKit rebuild the structural regions of EVERY
/// row's NSTrackingArea — profiled at ~15-20% of the main thread on long
/// chats. Hover affordances (copy buttons, row highlights) are dormant while
/// text is actively streaming anyway.
private struct HoverTrackingSuspendedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var hoverTrackingSuspended: Bool {
        get { self[HoverTrackingSuspendedKey.self] }
        set { self[HoverTrackingSuspendedKey.self] = newValue }
    }
}

extension View {
    /// AppKit-backed hover tracking that fires across the view's ENTIRE
    /// bounds, including fully transparent regions. SwiftUI's `.onHover`
    /// (like `.help`, see Tooltip.swift) doesn't reliably fire over
    /// transparent areas on macOS 26; an `NSTrackingArea` is geometric, so
    /// covered/clear pixels still count.
    func hoverTracking(_ isHovered: Binding<Bool>) -> some View {
        background(HoverTrackingView(isHovered: isHovered))
    }
}

private struct HoverTrackingView: NSViewRepresentable {
    @Binding var isHovered: Bool

    func makeNSView(context: Context) -> TrackingNSView {
        let view = TrackingNSView()
        view.onChange = { isHovered = $0 }
        view.isSuspended = context.environment.hoverTrackingSuspended
        return view
    }

    func updateNSView(_ view: TrackingNSView, context: Context) {
        view.onChange = { isHovered = $0 }
        view.isSuspended = context.environment.hoverTrackingSuspended
    }

    final class TrackingNSView: NSView {
        var onChange: ((Bool) -> Void)?
        var isSuspended = false {
            didSet {
                guard isSuspended != oldValue else { return }
                if isSuspended { onChange?(false) }
                updateTrackingAreas()
            }
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            guard !isSuspended else { return }
            addTrackingArea(NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                owner: self
            ))
        }

        override func mouseEntered(with event: NSEvent) { onChange?(true) }
        override func mouseExited(with event: NSEvent) { onChange?(false) }
    }
}
