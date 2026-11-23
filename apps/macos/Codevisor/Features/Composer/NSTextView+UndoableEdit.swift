import AppKit

extension NSTextView {
  func replaceAsUndoableEdit(_ range: NSRange, with replacement: String) {
    replaceAsUndoableEdit(range, with: NSAttributedString(string: replacement, attributes: typingAttributes))
  }

  func replaceAsUndoableEdit(_ range: NSRange, with replacement: NSAttributedString) {
    breakUndoCoalescing()
    guard shouldChangeText(in: range, replacementString: replacement.string) else { return }
    textStorage?.replaceCharacters(in: range, with: replacement)
    didChangeText()
    breakUndoCoalescing()
    let caret = NSRange(location: range.location + replacement.length, length: 0)
    setSelectedRange(caret)
    scrollRangeToVisible(caret)
  }
}
