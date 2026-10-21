import SwiftUI
import AppKit
import CodevisorCore
import ACPKit
import CodevisorUI

extension QuestionPickerContent {
  func notesBinding(_ question: QuestionSpec) -> Binding<String> {
    Binding(
      get: { notes[question.id] ?? "" },
      set: { notes[question.id] = $0 }
    )
  }

  private func rowCount(_ question: QuestionSpec) -> Int {
    question.options.count + (question.allowsOther ? 1 : 0)
  }

  func activate(_ question: QuestionSpec, index: Int) {
    let token = index >= question.options.count ? Self.otherToken : question.options[index].label
    var selected = selections[question.id, default: []]
    if question.multiSelect == true {
      if selected.contains(token) { selected.remove(token) } else { selected.insert(token) }
    } else {
      selected = selected.contains(token) ? [] : [token]
    }
    if isOtherSelected(question), !selected.contains(Self.otherToken),
      !revealedNotes.contains(question.id)
    {
      notes[question.id] = nil
    }
    selections[question.id] = selected
  }

  func isOtherSelected(_ question: QuestionSpec) -> Bool {
    selections[question.id, default: []].contains(Self.otherToken)
  }

  func showsNoteField(_ question: QuestionSpec) -> Bool {
    guard !isOtherSelected(question) else { return false }
    return revealedNotes.contains(question.id)
      || !(notes[question.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  func showsAddNoteButton(_ question: QuestionSpec) -> Bool {
    !isOtherSelected(question) && !showsNoteField(question)
  }

  func revealNote(_ question: QuestionSpec) {
    revealedNotes.insert(question.id)
    anchor.focusesNotesWhenReady = true
  }

  private func selectHighlighted(_ question: QuestionSpec, index: Int) {
    let token = index >= question.options.count ? Self.otherToken : question.options[index].label
    selections[question.id] = [token]
  }

  func moveQuestion(_ delta: Int) {
    let next = questionIndex + delta
    guard request.questions.indices.contains(next) else { return }
    questionIndex = next
    highlighted = 0
    focusPicker()
  }

  func focusPicker() {
    guard let view = anchor.view else { return }
    view.window?.makeFirstResponder(view)
  }

  func focusNotes() {
    if let view = anchor.notesEditor, let window = view.window {
      window.makeFirstResponder(view)
    } else {
      anchor.focusesNotesWhenReady = true
    }
  }

  func attachNotesEditor(_ textView: SubmittingTextView) {
    anchor.notesEditor = textView
    textView.onWindowChanged = { [weak textView, anchor] in
      guard anchor.focusesNotesWhenReady, let textView, let window = textView.window else { return }
      anchor.focusesNotesWhenReady = false
      window.makeFirstResponder(textView)
    }
  }

  func advanceOrSubmit() {
    if isLastQuestion {
      submit()
    } else {
      moveQuestion(1)
    }
  }

  func submit() {
    guard isSubmittable, !isResolving else { return }
    var answers: [String: QuestionAnswerEntry] = [:]
    for question in request.questions {
      let selected = selections[question.id, default: []]
      let note = (notes[question.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      let labels = question.options.map(\.label).filter { selected.contains($0) }
      if !labels.isEmpty || !note.isEmpty {
        answers[question.id] = QuestionAnswerEntry(
          answers: labels,
          note: note.isEmpty ? nil : note
        )
      }
    }
    didStartResolving = true
    Task {
      await controller.answerQuestion(answers: answers)
      didStartResolving = false
    }
  }

  func cancel() {
    guard !isResolving else { return }
    didStartResolving = true
    Task {
      await controller.cancelQuestion()
      didStartResolving = false
    }
  }

  func submitDirectAnswer(_ question: QuestionSpec, label: String) {
    guard !isResolving else { return }
    didStartResolving = true
    Task {
      await controller.answerQuestion(answers: [
        question.id: QuestionAnswerEntry(answers: [label])
      ])
      didStartResolving = false
    }
  }

  func handleKey(_ key: QuestionPickerKey) -> Bool {
    if isResolving { return true }
    guard let question else { return false }
    if infoOption != nil {
      infoOption = nil
      if key == .escape { return true }
    }
    switch key {
    case .up:
      highlighted = max(0, highlighted - 1)
      return true
    case .down:
      highlighted = min(rowCount(question) - 1, highlighted + 1)
      return true
    case .left:
      if let backOptionLabel = question.backOptionLabel {
        submitDirectAnswer(question, label: backOptionLabel)
      } else {
        moveQuestion(-1)
      }
      return true
    case .right:
      moveQuestion(1)
      return true
    case .space:
      activate(question, index: highlighted)
      return true
    case .enter:
      if question.multiSelect != true {
        selectHighlighted(question, index: highlighted)
      }
      let selected = selections[question.id, default: []]
      let note = (notes[question.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      if selected.contains(Self.otherToken), note.isEmpty {
        focusNotes()
        return true
      }
      advanceOrSubmit()
      return true
    case .escape:
      cancel()
      return true
    case .digit(let digit):
      guard digit >= 1, digit <= rowCount(question) else { return false }
      highlighted = digit - 1
      activate(question, index: digit - 1)
      return true
    }
  }
}
