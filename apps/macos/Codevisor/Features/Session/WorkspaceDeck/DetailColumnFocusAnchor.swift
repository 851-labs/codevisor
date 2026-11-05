import AppKit
import SwiftUI

@MainActor
final class DetailColumnFocusAnchor {
  fileprivate weak var view: NSView?

  func releaseFocus() {
    guard let window = view?.window, let column = column, let responder = window.firstResponder as? NSView,
      responder.isDescendant(of: column)
    else { return }
    window.makeFirstResponder(nil)
  }

  private var column: NSView? {
    var current = view
    while let candidate = current, let parent = candidate.superview {
      if parent is NSSplitView { return candidate }
      current = parent
    }
    return nil
  }

  struct Capture: NSViewRepresentable {
    let anchor: DetailColumnFocusAnchor

    func makeNSView(context: Context) -> NSView {
      let view = NSView()
      anchor.view = view
      return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
      anchor.view = nsView
    }
  }
}
