import SwiftUI

public extension View {
  func focusesAlertTextField(when isPresented: Bool) -> some View {
    #if os(macOS)
      modifier(AlertTextFieldFocus(isPresented: isPresented))
    #else
      self
    #endif
  }
}

#if os(macOS)
  import AppKit

  private struct AlertTextFieldFocus: ViewModifier {
    let isPresented: Bool

    func body(content: Content) -> some View {
      content.onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { notification in
        guard isPresented, let sheet = notification.object as? NSWindow, sheet.sheetParent != nil else { return }

        Self.selectTextField(in: sheet)
      }
    }

    private static func selectTextField(in sheet: NSWindow) {
      guard let field = editableTextField(in: sheet.contentView), field.currentEditor() == nil else { return }

      field.selectText(nil)
    }

    private static func editableTextField(in view: NSView?) -> NSTextField? {
      guard let view else { return nil }
      if let field = view as? NSTextField, field.isEditable { return field }

      return view.subviews.lazy.compactMap(editableTextField(in:)).first
    }
  }
#endif
