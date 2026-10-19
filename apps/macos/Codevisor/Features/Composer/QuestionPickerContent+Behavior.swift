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
    selections[question.id] = selected
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
    guard let view = anchor.notesEditor else { return }
    view.window?.makeFirstResponder(view)
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
    if isBrowserExtensionPresentation(question) {
      return handleBrowserExtensionKey(key, question: question)
    }
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

  private func handleBrowserExtensionKey(_ key: QuestionPickerKey, question: QuestionSpec) -> Bool {
    if !canInstallBrowserExtensionLocally {
      switch key {
      case .enter, .space, .left:
        if let backOptionLabel = question.backOptionLabel {
          submitDirectAnswer(question, label: backOptionLabel)
        }
        return true
      case .escape:
        cancel()
        return true
      case .right, .up, .down, .digit:
        return true
      }
    }
    switch key {
    case .enter, .space:
      if !didOpenBrowserExtensions {
        performBrowserSetupAction("Open Extensions")
      }
      return true
    case .left:
      if didOpenBrowserExtensions {
        showBrowserExtensionDragStage(false)
      } else if let backOptionLabel = question.backOptionLabel {
        submitDirectAnswer(question, label: backOptionLabel)
      }
      return true
    case .right:
      if !didOpenBrowserExtensions {
        showBrowserExtensionDragStage(true)
      }
      return true
    case .escape:
      cancel()
      return true
    case .up, .down, .digit:
      return true
    }
  }
}
