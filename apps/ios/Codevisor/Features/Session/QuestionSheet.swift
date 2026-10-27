import ACPKit
import CodevisorCore
import CodevisorUI
import SwiftUI

struct QuestionSheet: View {
  let controller: SessionController
  let request: QuestionRequest

  @Environment(\.dismiss) private var dismiss
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @FocusState private var isAnswerFieldFocused: Bool
  @State private var detent: PresentationDetent = .medium

  static let answerFieldID = "answer"

  private var draft: QuestionDraft { controller.questionDraft(for: request) }

  var body: some View {
    NavigationStack {
      if let question = draft.question {
        ScrollViewReader { proxy in
          ScrollView {
            QuestionSheetPage(
              draft: draft, question: question, isAnswerFieldFocused: $isAnswerFieldFocused, onChoose: choose,
              onReturn: handleReturn
            )
            .id(question.id)
            .transition(pageTransition)
          }
          .scrollDismissesKeyboard(.interactively)
          .onChange(of: isAnswerFieldFocused) { _, focused in
            guard focused else { return }
            detent = .large
            withAnimation(Motion.quick(reduceMotion: reduceMotion)) {
              proxy.scrollTo(Self.answerFieldID, anchor: .bottom)
            }
          }
        }
        .safeAreaInset(edge: .bottom) {
          QuestionSheetFooter(
            draft: draft, question: question, isSubmitting: controller.isResolvingQuestion,
            actions: footerActions(question)
          )
          .padding(.horizontal, 20)
          .padding(.vertical, 12)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button(role: .close) { dismiss() }
          }
        }
      }
    }
    .disabled(controller.transcriptQuestion?.questionId != request.questionId)
    .animation(Motion.quick(reduceMotion: reduceMotion), value: draft.page)
    .animation(Motion.quick(reduceMotion: reduceMotion), value: draft.selections)
    .sensoryFeedback(.selection, trigger: draft.selections)
    .presentationDetents([.medium, .large], selection: $detent)
    .presentationDragIndicator(.visible)
  }

  private var title: String {
    guard draft.pageCount > 1 else { return "Question" }
    return "Question \(draft.page + 1) of \(draft.pageCount)"
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

  private func footerActions(_ question: QuestionSpec) -> QuestionSheetFooter.Actions {
    QuestionSheetFooter.Actions(
      back: { page(by: -1) },
      next: { page(by: 1) },
      submit: submit,
      answerDirectly: { label in answer([question.id: QuestionAnswerEntry(answers: [label])]) }
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

private struct QuestionSheetPage: View {
  let draft: QuestionDraft
  let question: QuestionSpec
  var isAnswerFieldFocused: FocusState<Bool>.Binding
  let onChoose: (String, QuestionSpec) -> Void
  let onReturn: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      if let message = draft.request.message, !message.isEmpty, draft.page == 0 {
        Text(message)
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
      Text(question.question)
        .font(.title3.weight(.semibold))
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityAddTraits(.isHeader)
      QuestionSheetOptions(draft: draft, question: question, onChoose: onChoose)
      if draft.isOtherSelected(question) {
        QuestionAnswerField(draft: draft, question: question, isFocused: isAnswerFieldFocused, onReturn: onReturn)
          .id(QuestionSheet.answerFieldID)
      }
    }
    .padding(.horizontal, 20)
    .padding(.top, 8)
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct QuestionSheetOptions: View {
  let draft: QuestionDraft
  let question: QuestionSpec
  let onChoose: (String, QuestionSpec) -> Void

  var body: some View {
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
      .lineLimit(1...6)
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
