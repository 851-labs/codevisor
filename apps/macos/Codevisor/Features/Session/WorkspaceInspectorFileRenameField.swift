import AppKit
import SwiftUI

struct WorkspaceInspectorFileRenameField: NSViewRepresentable {
  let original: String
  let isDirectory: Bool
  let onCommit: (String, Bool) -> Void
  let onCancel: () -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(onCommit: onCommit, onCancel: onCancel)
  }

  func makeNSView(context: Context) -> FieldView {
    let field = FieldView(string: original)
    field.selection = Self.initialSelection(of: original, isDirectory: isDirectory)
    field.delegate = context.coordinator
    field.isBezeled = false
    field.isBordered = false
    field.drawsBackground = true
    field.backgroundColor = .textBackgroundColor
    field.textColor = .textColor
    field.focusRingType = .exterior
    field.font = .systemFont(ofSize: NSFont.systemFontSize)
    field.cell?.isScrollable = true
    field.setContentHuggingPriority(.required, for: .horizontal)
    field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return field
  }

  func updateNSView(_ field: FieldView, context: Context) {
    context.coordinator.onCommit = onCommit
    context.coordinator.onCancel = onCancel
  }

  static func initialSelection(of name: String, isDirectory: Bool) -> NSRange {
    let whole = NSRange(location: 0, length: (name as NSString).length)
    let stem = (name as NSString).deletingPathExtension
    guard !isDirectory, !stem.isEmpty else { return whole }
    return NSRange(location: 0, length: (stem as NSString).length)
  }

  final class FieldView: NSTextField {
    private static let textPadding: CGFloat = 8

    var selection = NSRange(location: 0, length: 0)

    override var intrinsicContentSize: NSSize {
      let text = currentEditor()?.string ?? stringValue
      let measuringFont = font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
      let width = (text as NSString).size(withAttributes: [.font: measuringFont]).width
      return NSSize(width: width.rounded(.up) + Self.textPadding, height: super.intrinsicContentSize.height)
    }

    override func textDidChange(_ notification: Notification) {
      super.textDidChange(notification)
      invalidateIntrinsicContentSize()
    }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      guard let window else { return }

      window.makeFirstResponder(self)
      currentEditor()?.selectedRange = selection
    }
  }

  final class Coordinator: NSObject, NSTextFieldDelegate {
    var onCommit: (String, Bool) -> Void
    var onCancel: () -> Void
    private var isFinished = false

    init(onCommit: @escaping (String, Bool) -> Void, onCancel: @escaping () -> Void) {
      self.onCommit = onCommit
      self.onCancel = onCancel
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
      switch selector {
      case #selector(NSResponder.insertNewline(_:)):
        finish { onCommit(control.stringValue, true) }
        return true
      case #selector(NSResponder.cancelOperation(_:)):
        finish { onCancel() }
        return true
      default:
        return false
      }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
      guard let field = notification.object as? NSTextField else { return }

      finish { onCommit(field.stringValue, false) }
    }

    private func finish(_ action: () -> Void) {
      guard !isFinished else { return }

      isFinished = true
      action()
    }
  }
}
