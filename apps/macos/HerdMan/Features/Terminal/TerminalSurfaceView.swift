import SwiftUI
import AppKit

/// Embeds a session's terminal surface. Hosts the surface's `NSView` inside a
/// container pinned to the edges; because the surface is cached on the
/// `TerminalSession`, the same view (and its live shell) is re-parented each
/// time the panel reopens, preserving terminal state.
struct TerminalSurfaceView: NSViewRepresentable {
    let session: TerminalSession

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        attach(to: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        attach(to: container)
    }

    @MainActor
    private func attach(to container: NSView) {
        let surfaceView = session.ensureSurface().nsView
        guard surfaceView.superview !== container else { return }
        surfaceView.removeFromSuperview()
        container.subviews.forEach { $0.removeFromSuperview() }
        surfaceView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(surfaceView)
        NSLayoutConstraint.activate([
            surfaceView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            surfaceView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            surfaceView.topAnchor.constraint(equalTo: container.topAnchor),
            surfaceView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
    }
}
