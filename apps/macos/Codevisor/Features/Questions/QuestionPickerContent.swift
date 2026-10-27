import ACPKit
import AppKit
import CodevisorCore
import CodevisorUI
import SwiftUI

struct QuestionPickerContent: View {
  let draft: QuestionDraft
  let isResolving: Bool
  let chrome: QuestionPickerChrome
  let actions: QuestionPickerActions
  var focus: TerminalFocusController? = nil
  var chatId: UUID? = nil
  var onTypeText: ((NSEvent) -> Void)? = nil

  @Environment(\.transcriptInvalidateRowMeasurement) private var invalidateRowMeasurement
  @State private var highlighted = 0
  @State private var hasKeyboardFocus = false
  @State private var focusTargets = QuestionPickerFocusTargets()

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      if let question = draft.question {
        QuestionPickerMessage(message: draft.request.message, page: draft.page)
        QuestionPickerHeader(draft: draft, question: question, chrome: chrome, onDismiss: actions.dismiss)
        QuestionOptionList(
          draft: draft,
          question: question,
          highlighted: $highlighted,
          showsHighlight: hasKeyboardFocus,
          focusTargets: focusTargets,
          onSubmit: advanceOrSubmit
        )
        if asksForPlanFeedback(question) {
          QuestionAnswerEditor(
            draft: draft, question: question, placeholder: "What should change? (optional)",
            focusTargets: focusTargets, onSubmit: advanceOrSubmit
          )
          .padding(.horizontal, 10)
          .padding(.vertical, 4)
          .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.1)))
        }
        QuestionPickerFooter(draft: draft, question: question, actions: actions)
      }
    }
    .disabled(isResolving)
    .background(focusAnchor)
    .onChange(of: draft.page) { _, _ in
      highlighted = 0
      focusTargets.focusPicker()
      invalidateRowMeasurement?()
    }
    .onChange(of: draft.selections) { _, _ in invalidateRowMeasurement?() }
    .onChange(of: asksForPlanFeedback) { _, asks in
      if asks { focusTargets.focusAnswerEditorWhenReady() }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Agent question")
  }

  private var focusAnchor: some View {
    QuestionPickerFocusAnchor(
      onAttach: attach,
      onKey: { keyHandler.handle($0) },
      onText: { onTypeText?($0) },
      onFocusChange: { hasKeyboardFocus = $0 },
      onDetach: detach
    )
  }

  private func attach(_ view: QuestionPickerKeyView) {
    focusTargets.picker = view
    if let focus, let chatId {
      focus.registerQuestionPicker(view, forChat: chatId)
    } else {
      view.window?.makeFirstResponder(view)
    }
  }

  private func detach(_ view: QuestionPickerKeyView) {
    guard let focus, let chatId else { return }
    focus.unregisterQuestionPicker(view, forChat: chatId)
  }

  private var keyHandler: QuestionPickerKeyHandler {
    QuestionPickerKeyHandler(
      draft: draft,
      actions: actions,
      isResolving: isResolving,
      highlighted: $highlighted,
      focusAnswerEditor: focusTargets.focusAnswerEditor,
      advanceOrSubmit: advanceOrSubmit
    )
  }

  private var asksForPlanFeedback: Bool {
    draft.question.map(asksForPlanFeedback) ?? false
  }

  private func asksForPlanFeedback(_ question: QuestionSpec) -> Bool {
    question.id == QuestionRequest.exitPlanModeId && draft.isSelected(QuestionRequest.keepPlanningLabel, in: question)
  }

  private func advanceOrSubmit() {
    if draft.isLastPage {
      actions.submit()
    } else {
      draft.move(by: 1)
    }
  }
}

private struct QuestionPickerMessage: View {
  let message: String?
  let page: Int

  var body: some View {
    if let message, !message.isEmpty, page == 0 {
      Text(message)
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}
