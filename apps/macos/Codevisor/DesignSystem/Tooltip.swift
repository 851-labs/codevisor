import SwiftUI
import AppKit

extension View {
    /// AppKit-backed tooltip. SwiftUI's `.help()` doesn't reliably display
    /// tooltips in this app (macOS 26), so this installs a real
    /// `NSView.toolTip` behind the content: plain SwiftUI drawing above it is
    /// not an NSView, so the tooltip manager finds this view under the
    /// cursor, while clicks fall through the responder chain back to the
    /// hosting view's SwiftUI controls.
    func tooltip(_ text: String) -> some View {
        background(TooltipBackground(text: text))
    }
}

private struct TooltipBackground: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.toolTip = text
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        view.toolTip = text
    }
}
