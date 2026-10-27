import ACPKit
import CodevisorCore
import CodevisorUI
import SwiftUI
import UIKit

struct TranscriptQuestionCard: View {
  let controller: SessionController
  let request: QuestionRequest
  let inBotConversation: Bool

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.transcriptInvalidateRowMeasurement) private var invalidateRowMeasurement
  @State private var otherFocusRequest: UUID?

  private var draft: QuestionDraft { controller.questionDraft(for: request) }

  private var isAnswerable: Bool {
    controller.transcriptQuestion?.questionId == request.questionId && !controller.isResolvingQuestion
  }

  var body: some View {
    TranscriptQuestionContainer(inBotConversation: inBotConversation) {
      if let question = draft.question {
        VStack(alignment: .leading, spacing: 12) {
          QuestionCardHeading(draft: draft, question: question)
          QuestionCardOptions(
            draft: draft,
            question: question,
            otherFocusRequest: otherFocusRequest,
            onChoose: choose,
            onOtherFocusChange: otherFocusChanged,
            onOtherHeightChange: revealCard
          )
          .id(question.id)
          .transition(pageTransition)
          QuestionCardFooter(
            draft: draft,
            question: question,
            isSubmitting: controller.isResolvingQuestion,
            actions: footerActions(question)
          )
        }
      }
    }
    .disabled(!isAnswerable)
    .animation(Motion.quick(reduceMotion: reduceMotion), value: draft.page)
    .animation(Motion.quick(reduceMotion: reduceMotion), value: draft.selections)
    .sensoryFeedback(.selection, trigger: draft.selections)
    .onChange(of: draft.page) { _, _ in invalidateRowMeasurement?() }
    .onChange(of: draft.selections) { _, _ in invalidateRowMeasurement?() }
    .onDisappear { controller.isTypingTranscriptAnswer = false }
  }

  private var pageTransition: AnyTransition {
    guard !reduceMotion else { return .opacity }
    return .push(from: draft.isPagingForward ? .trailing : .leading)
  }

  private func choose(_ label: String, in question: QuestionSpec) {
    guard label == QuestionDraft.otherToken else {
      draft.pick(label, in: question)
      return
    }
    draft.toggle(label, in: question)
    otherFocusRequest = draft.isOtherSelected(question) ? UUID() : nil
  }

  private func otherFocusChanged(_ focused: Bool) {
    controller.isTypingTranscriptAnswer = focused
    revealCard()
  }

  private func revealCard() {
    invalidateRowMeasurement?()
    guard controller.isTypingTranscriptAnswer else { return }
    controller.revealTranscriptQuestion()
  }

  private func footerActions(_ question: QuestionSpec) -> QuestionCardFooter.Actions {
    QuestionCardFooter.Actions(
      back: { page(by: -1) },
      next: { page(by: 1) },
      submit: submit,
      answerDirectly: { label in answer([question.id: QuestionAnswerEntry(answers: [label])]) }
    )
  }

  private func page(by delta: Int) {
    endTyping()
    draft.move(by: delta)
  }

  private func endTyping() {
    otherFocusRequest = nil
    controller.isTypingTranscriptAnswer = false
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
  }

  private func submit() {
    endTyping()
    let id = request.questionId
    Task { await controller.submitTranscriptQuestion(id) }
  }

  private func answer(_ entries: [String: QuestionAnswerEntry]) {
    endTyping()
    let id = request.questionId
    Task { await controller.answerTranscriptQuestion(id, with: entries) }
  }
}

private struct QuestionCardHeading: View {
  let draft: QuestionDraft
  let question: QuestionSpec

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(caption)
        .font(.footnote.weight(.medium))
        .foregroundStyle(.secondary)
      Text(question.question)
        .font(.headline)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityAddTraits(.isHeader)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var caption: String {
    let header = question.header.map { " · \($0)" } ?? ""
    guard draft.pageCount > 1 else { return "Question\(header)" }
    return "Question \(draft.page + 1) of \(draft.pageCount)\(header)"
  }
}

private struct QuestionCardOptions: View {
  let draft: QuestionDraft
  let question: QuestionSpec
  let otherFocusRequest: UUID?
  let onChoose: (String, QuestionSpec) -> Void
  let onOtherFocusChange: (Bool) -> Void
  let onOtherHeightChange: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      if let message = draft.request.message, !message.isEmpty, draft.page == 0 {
        Text(message)
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
      VStack(spacing: 8) {
        ForEach(question.options) { option in
          QuestionOptionRow(
            title: option.label,
            description: option.description,
            indicator: indicator,
            isSelected: draft.isSelected(option.label, in: question),
            action: { onChoose(option.label, question) }
          )
        }
        if question.allowsOther {
          QuestionOtherRow(
            draft: draft,
            question: question,
            indicator: indicator,
            focusRequest: otherFocusRequest,
            onToggle: { onChoose(QuestionDraft.otherToken, question) },
            onFocusChange: onOtherFocusChange,
            onHeightChange: onOtherHeightChange
          )
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var indicator: QuestionOptionIndicator {
    question.multiSelect == true ? .multiple : .single
  }
}
