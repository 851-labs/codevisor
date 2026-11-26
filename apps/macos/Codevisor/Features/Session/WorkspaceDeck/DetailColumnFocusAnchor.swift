import AppKit
import SwiftUI

@MainActor
final class DetailColumnFocusAnchor {
  fileprivate weak var view: NSView?

  var focusOwner: AnyObject? {
    Self.owner(of: view?.window?.firstResponder)
  }

  var isFocusInColumnOrNowhere: Bool {
    guard let window = view?.window, let column else { return false }
    guard let responder = window.firstResponder as? NSView else { return true }

    return responder.isDescendant(of: column)
  }

  func releaseFocus(heldBy previous: AnyObject?) {
    guard let window = view?.window, let column = column, let responder = window.firstResponder as? NSView,
      Self.owner(of: responder) === previous, responder.isDescendant(of: column)
    else { return }
    window.makeFirstResponder(nil)
  }

  private static func owner(of responder: NSResponder?) -> AnyObject? {
    if let editor = responder as? NSText, editor.isFieldEditor, let field = editor.delegate { return field }
    return responder
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
