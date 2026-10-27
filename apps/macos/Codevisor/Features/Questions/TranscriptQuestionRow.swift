import ACPKit
import CodevisorCore
import CodevisorUI
import SwiftUI
import TranscriptKit

struct TranscriptQuestionRow: View {
  let interaction: TranscriptInteraction
  let inBotConversation: Bool
  let controller: SessionController
  let focus: TerminalFocusController?

  var body: some View {
    switch interaction.content {
    case let .question(question):
      if question.answer == nil {
        PendingTranscriptQuestion(
          request: question.request,
          inBotConversation: inBotConversation,
          controller: controller,
          focus: focus
        )
      } else {
        TranscriptQuestionSummaryView(question: question, inBotConversation: inBotConversation)
      }
    }
  }
}

private struct PendingTranscriptQuestion: View {
  let request: QuestionRequest
  let inBotConversation: Bool
  let controller: SessionController
  let focus: TerminalFocusController?

  var body: some View {
    let draft = controller.questionDraft(for: request)
    TranscriptQuestionContainer(inBotConversation: inBotConversation) {
      QuestionPickerContent(
        draft: draft,
        isResolving: !isAnswerable || controller.isResolvingQuestion,
        chrome: .transcript,
        actions: actions(draft),
        focus: isAnswerable ? focus : nil,
        chatId: isAnswerable ? controller.serverSession?.id : nil,
        onTypeText: typeIntoComposer
      )
    }
  }

  private var isAnswerable: Bool {
    controller.transcriptQuestion?.questionId == request.questionId
  }

  private func actions(_ draft: QuestionDraft) -> QuestionPickerActions {
    let id = request.questionId
    return QuestionPickerActions(
      submit: { Task { await controller.submitTranscriptQuestion(id) } },
      dismiss: focusComposer,
      answerDirectly: { spec, label in
        Task { await controller.answerTranscriptQuestion(id, with: [spec.id: QuestionAnswerEntry(answers: [label])]) }
      }
    )
  }

  private func focusComposer() {
    guard let focus, let chatId = controller.serverSession?.id else { return }
    focus.focusComposerText(forChat: chatId)
  }

  private func typeIntoComposer(_ event: NSEvent) {
    guard let focus, let chatId = controller.serverSession?.id else { return }
    focus.typeIntoComposer(event, forChat: chatId)
  }
}
