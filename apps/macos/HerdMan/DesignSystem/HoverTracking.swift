import SwiftUI
import AppKit

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
        return view
    }

    func updateNSView(_ view: TrackingNSView, context: Context) {
        view.onChange = { isHovered = $0 }
    }

    final class TrackingNSView: NSView {
        var onChange: ((Bool) -> Void)?

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
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
