import SwiftUI
import AppKit

struct TerminalSurfaceView: NSViewRepresentable {
  let pane: TerminalPane

  final class SurfaceContainerView: NSView {
    var reclaim: (() -> Void)?
    var onAttach: (() -> Void)?

    override func layout() {
      super.layout()
      reclaim?()
    }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      if window != nil {
        reclaim?()
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
  private static func attach(pane: TerminalPane, to container: NSView) {
    let surfaceView = pane.ensureSurface().nsView
    guard surfaceView.superview !== container else { return }
    if surfaceView.superview != nil,
      container.window == nil, container.superview == nil
    {
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
      surfaceView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
    ])
  }
}
