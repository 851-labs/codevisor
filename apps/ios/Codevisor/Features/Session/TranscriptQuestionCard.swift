import ACPKit
import CodevisorCore
import CodevisorUI
import SwiftUI

struct TranscriptQuestionCard: View {
  let controller: SessionController
  let request: QuestionRequest
  let inBotConversation: Bool

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.transcriptInvalidateRowMeasurement) private var invalidateRowMeasurement
  @FocusState private var isAnswerFieldFocused: Bool

  private var draft: QuestionDraft { controller.questionDraft(for: request) }

  private var isAnswerable: Bool {
    controller.transcriptQuestion?.questionId == request.questionId && !controller.isResolvingQuestion
  }

  var body: some View {
    TranscriptQuestionContainer(inBotConversation: inBotConversation) {
      if let question = draft.question {
        VStack(alignment: .leading, spacing: 12) {
          QuestionCardHeading(draft: draft, question: question, isTyping: isAnswerFieldFocused)
          if !isAnswerFieldFocused {
            QuestionCardOptions(draft: draft, question: question, onChoose: choose)
              .id(question.id)
              .transition(pageTransition)
          }
          if draft.isOtherSelected(question) {
            QuestionAnswerField(
              draft: draft, question: question, isFocused: $isAnswerFieldFocused, onReturn: handleReturn)
          }
          QuestionCardFooter(
            draft: draft,
            question: question,
            isTyping: isAnswerFieldFocused,
            isSubmitting: controller.isResolvingQuestion,
            actions: footerActions(question)
          )
        }
      }
    }
    .disabled(!isAnswerable)
    .animation(Motion.quick(reduceMotion: reduceMotion), value: draft.page)
    .animation(Motion.quick(reduceMotion: reduceMotion), value: draft.selections)
    .animation(Motion.quick(reduceMotion: reduceMotion), value: isAnswerFieldFocused)
    .sensoryFeedback(.selection, trigger: draft.selections)
    .onChange(of: draft.page) { _, _ in invalidateRowMeasurement?() }
    .onChange(of: draft.selections) { _, _ in invalidateRowMeasurement?() }
    .onChange(of: isAnswerFieldFocused) { _, focused in
      invalidateRowMeasurement?()
      if focused { controller.revealTranscriptQuestion() }
    }
  }

  private var pageTransition: AnyTransition {
    guard !reduceMotion else { return .opacity }
    return .push(from: draft.isPagingForward ? .trailing : .leading)
  }

  private func choose(_ label: String, in question: QuestionSpec) {
    draft.toggle(label, in: question)
    guard label == QuestionDraft.otherToken else { return }
    isAnswerFieldFocused = draft.isOtherSelected(question)
  }

  private func footerActions(_ question: QuestionSpec) -> QuestionCardFooter.Actions {
    QuestionCardFooter.Actions(
      back: { page(by: -1) },
      next: { page(by: 1) },
      submit: submit,
      answerDirectly: { label in answer([question.id: QuestionAnswerEntry(answers: [label])]) },
      dismissKeyboard: { isAnswerFieldFocused = false }
    )
  }

  private func handleReturn() {
    if !draft.isLastPage {
      page(by: 1)
    } else if draft.isSubmittable {
      submit()
    } else {
      isAnswerFieldFocused = false
    }
  }

  private func page(by delta: Int) {
    isAnswerFieldFocused = false
    draft.move(by: delta)
  }

  private func submit() {
    isAnswerFieldFocused = false
    let id = request.questionId
    Task { await controller.submitTranscriptQuestion(id) }
  }

  private func answer(_ entries: [String: QuestionAnswerEntry]) {
    isAnswerFieldFocused = false
    let id = request.questionId
    Task { await controller.answerTranscriptQuestion(id, with: entries) }
  }
}

private struct QuestionCardHeading: View {
  let draft: QuestionDraft
  let question: QuestionSpec
  let isTyping: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(caption)
        .font(.footnote.weight(.medium))
        .foregroundStyle(.secondary)
      Text(question.question)
        .font(isTyping ? .subheadline.weight(.semibold) : .headline)
        .foregroundStyle(isTyping ? .secondary : .primary)
        .lineLimit(isTyping ? 2 : nil)
        .fixedSize(horizontal: false, vertical: !isTyping)
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
  let onChoose: (String, QuestionSpec) -> Void

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
          QuestionOptionRow(
            title: "Other",
            description: nil,
            indicator: indicator,
            isSelected: draft.isOtherSelected(question),
            action: { onChoose(QuestionDraft.otherToken, question) }
          )
          .accessibilityHint("Type your own answer")
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var indicator: QuestionOptionIndicator {
    question.multiSelect == true ? .multiple : .single
  }
}

private struct QuestionAnswerField: View {
  let draft: QuestionDraft
  let question: QuestionSpec
  var isFocused: FocusState<Bool>.Binding
  let onReturn: () -> Void

  private let shape = ComposerCardStyle().insetShape(by: ComposerCardStyle.contentPadding)

  var body: some View {
    TextField("Your answer", text: text, axis: .vertical)
      .font(.body)
      .lineLimit(1...4)
      .focused(isFocused)
      .submitLabel(draft.isLastPage ? .send : .next)
      .padding(.horizontal, 14)
      .padding(.vertical, 12)
      .frame(minHeight: 48)
      .background(shape.fill(HierarchicalShapeStyle.quaternary.opacity(0.6)))
      .overlay(shape.stroke(Color.accentColor.opacity(isFocused.wrappedValue ? 0.55 : 0), lineWidth: 1.5))
      .accessibilityLabel("Your answer")
  }

  private var text: Binding<String> {
    Binding(
      get: { draft.typedAnswer(for: question) },
      set: { newValue in
        guard newValue.contains("\n") else {
          draft.setTypedAnswer(newValue, for: question)
          return
        }
        draft.setTypedAnswer(newValue.replacingOccurrences(of: "\n", with: ""), for: question)
        onReturn()
      }
    )
  }
}
