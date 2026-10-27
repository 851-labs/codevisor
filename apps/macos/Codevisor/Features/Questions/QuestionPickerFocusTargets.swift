import AppKit

@MainActor
final class QuestionPickerFocusTargets {
  weak var picker: QuestionPickerKeyView?
  weak var notesEditor: SubmittingTextView?
  private var focusesNotesWhenReady = false

  func focusPicker() {
    guard let picker else { return }
    picker.window?.makeFirstResponder(picker)
  }

  func focusNotes() {
    guard let notesEditor, let window = notesEditor.window else {
      focusesNotesWhenReady = true
      return
    }
    window.makeFirstResponder(notesEditor)
  }

  func focusNotesWhenReady() {
    focusesNotesWhenReady = true
  }

  func attachNotesEditor(_ textView: SubmittingTextView) {
    notesEditor = textView
    textView.onWindowChanged = { [weak self, weak textView] in
      guard let self, let textView, self.focusesNotesWhenReady, let window = textView.window else { return }
      self.focusesNotesWhenReady = false
      window.makeFirstResponder(textView)
    }
  }
}
