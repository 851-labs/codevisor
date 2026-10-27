import AppKit

@MainActor
final class QuestionPickerFocusTargets {
  weak var picker: QuestionPickerKeyView?
  weak var answerEditor: SubmittingTextView?
  private var focusesAnswerEditorWhenReady = false

  func focusPicker() {
    guard let picker else { return }
    picker.window?.makeFirstResponder(picker)
  }

  func focusAnswerEditor() {
    guard let answerEditor, let window = answerEditor.window else {
      focusesAnswerEditorWhenReady = true
      return
    }
    window.makeFirstResponder(answerEditor)
  }

  func focusAnswerEditorWhenReady() {
    focusesAnswerEditorWhenReady = true
  }

  func attachAnswerEditor(_ textView: SubmittingTextView) {
    answerEditor = textView
    textView.onWindowChanged = { [weak self, weak textView] in
      guard let self, let textView, self.focusesAnswerEditorWhenReady, let window = textView.window else { return }
      self.focusesAnswerEditorWhenReady = false
      window.makeFirstResponder(textView)
    }
  }
}
