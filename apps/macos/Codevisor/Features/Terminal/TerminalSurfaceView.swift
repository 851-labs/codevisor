import SwiftUI
import AppKit

struct TerminalSurfaceView: NSViewRepresentable {
  let pane: TerminalPane

  final class SurfaceContainerView: NSView {
    var reclaim: (() -> Void)?
    var onAttach: (() -> Void)?
    weak var movedResponder: NSView?

    func restoreMovedResponder() {
      guard let responder = movedResponder, let window, responder.window === window else { return }
      movedResponder = nil
      window.makeFirstResponder(responder)
    }

    override func layout() {
      super.layout()
      reclaim?()
    }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      if window != nil {
        reclaim?()
        restoreMovedResponder()
        onAttach?()
      }
    }
  }

  func makeNSView(context: Context) -> SurfaceContainerView {
    let container = SurfaceContainerView()
    container.onAttach = { pane.onContentAttached?() }
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
  private static func attach(pane: TerminalPane, to container: SurfaceContainerView) {
    let surfaceView = pane.ensureSurface().nsView
    guard surfaceView.superview !== container else { return }
    if surfaceView.superview != nil,
      container.window == nil, container.superview == nil
    {
      return
    }
    container.movedResponder = focusedResponder(in: surfaceView)
    surfaceView.removeFromSuperview()
    container.subviews.forEach { $0.removeFromSuperview() }
    surfaceView.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(surfaceView)
    NSLayoutConstraint.activate([
      surfaceView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      surfaceView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      surfaceView.topAnchor.constraint(equalTo: container.topAnchor),
      surfaceView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
    ])
    container.restoreMovedResponder()
  }

  @MainActor
  private static func focusedResponder(in surfaceView: NSView) -> NSView? {
    guard let responder = surfaceView.window?.firstResponder as? NSView,
      responder === surfaceView || responder.isDescendant(of: surfaceView)
    else { return nil }
    return responder
  }
}
