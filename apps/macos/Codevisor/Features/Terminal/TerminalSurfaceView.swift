import SwiftUI
import AppKit

/// Embeds a terminal pane's surface. Hosts the surface's `NSView` inside a
/// container pinned to the edges; because the surface is cached on the
/// `TerminalPane`, the same view (and its live shell) is re-parented each
/// time the pane reappears, preserving terminal state.
///
/// Attachment is idempotent AND self-healing: when a split dissolves,
/// SwiftUI can interleave the old host's teardown with the new host's
/// creation, and a one-shot attach can leave the surface orphaned on a
/// dead container (a blank terminal). The container re-adopts the surface
/// on every layout pass — only live, windowed containers get layout, so
/// ownership converges on the visible host.
struct TerminalSurfaceView: NSViewRepresentable {
    let pane: TerminalPane

    final class SurfaceContainerView: NSView {
        var reclaim: (() -> Void)?

        override func layout() {
            super.layout()
            reclaim?()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil {
                reclaim?()
            }
        }
    }

    func makeNSView(context: Context) -> SurfaceContainerView {
        let container = SurfaceContainerView()
        container.reclaim = { [weak container] in
            guard let container else { return }
            Self.attach(pane: pane, to: container)
        }
        Self.attach(pane: pane, to: container)
        return container
    }

    func updateNSView(_ container: SurfaceContainerView, context: Context) {
        container.reclaim = { [weak container] in
            guard let container else { return }
            Self.attach(pane: pane, to: container)
        }
        Self.attach(pane: pane, to: container)
    }

    @MainActor
    private static func attach(pane: TerminalPane, to container: NSView) {
        let surfaceView = pane.ensureSurface().nsView
        guard surfaceView.superview !== container else { return }
        // Never STEAL an attached surface into a detached container: a
        // dying host's late callbacks must not pull it off the live one.
        // (A fresh makeNSView container is allowed to take an ORPHANED
        // surface — superview nil — before it lands in the window.)
        if surfaceView.superview != nil,
           container.window == nil, container.superview == nil {
            return
        }
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
