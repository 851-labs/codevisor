import ACPKit
import CodevisorCore
import CodevisorUI
import SwiftUI

@MainActor
struct QuestionPickerKeyHandler {
  let draft: QuestionDraft
  let actions: QuestionPickerActions
  let isResolving: Bool
  @Binding var highlighted: Int
  let focusAnswerEditor: () -> Void
  let advanceOrSubmit: () -> Void

  func handle(_ key: QuestionPickerKey) -> Bool {
    if isResolving { return true }
    guard let question = draft.question else { return false }

    switch key {
    case .up: highlighted = max(0, highlighted - 1)
    case .down: highlighted = min(rowCount(question) - 1, highlighted + 1)
    case .left: moveBack(question)
    case .right: draft.move(by: 1)
    case .space: draft.toggle(token(question, at: highlighted), in: question)
    case .enter: enter(question)
    case .escape: actions.dismiss()
    case let .digit(digit): return choose(digit, in: question)
    }
    return true
  }

  private func rowCount(_ question: QuestionSpec) -> Int {
    question.options.count + (question.allowsOther ? 1 : 0)
  }

  private func token(_ question: QuestionSpec, at index: Int) -> String {
    index >= question.options.count ? QuestionDraft.otherToken : question.options[index].label
  }

  private func moveBack(_ question: QuestionSpec) {
    guard let backOptionLabel = question.backOptionLabel else {
      draft.move(by: -1)
      return
    }
    actions.answerDirectly(question, backOptionLabel)
  }

  private func enter(_ question: QuestionSpec) {
    if question.multiSelect != true { draft.select(token(question, at: highlighted), in: question) }
    guard !draft.isOtherSelected(question) || !draft.trimmedTypedAnswer(question).isEmpty else {
      focusAnswerEditor()
      return
    }
    advanceOrSubmit()
  }

  private func choose(_ digit: Int, in question: QuestionSpec) -> Bool {
    guard digit >= 1, digit <= rowCount(question) else { return false }
    highlighted = digit - 1
    draft.toggle(token(question, at: digit - 1), in: question)
    return true
  }
}
