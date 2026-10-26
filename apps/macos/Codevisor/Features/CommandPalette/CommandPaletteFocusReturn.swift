import AppKit

struct CommandPaletteFocusReturn {
  private weak var window: NSWindow?
  private weak var responder: NSResponder?

  init(window: NSWindow) {
    self.window = window
    responder = Self.owner(of: window.firstResponder)
  }

  func restore() {
    guard let window, let responder, isStillShown(responder, in: window) else { return }

    window.makeFirstResponder(responder)
  }

  private func isStillShown(_ responder: NSResponder, in window: NSWindow) -> Bool {
    guard let view = responder as? NSView else { return responder === window }
    return view.window === window
  }

  private static func owner(of responder: NSResponder?) -> NSResponder? {
    guard let editor = responder as? NSTextView, editor.isFieldEditor else { return responder }
    return editor.delegate as? NSResponder
  }
}
