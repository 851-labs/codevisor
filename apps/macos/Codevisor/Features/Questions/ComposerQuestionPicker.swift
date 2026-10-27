import ACPKit
import CodevisorCore
import CodevisorUI
import SwiftUI

struct ComposerQuestionPicker: View {
  let controller: SessionController
  let request: QuestionRequest
  @Binding var didStartResolving: Bool
  var focus: TerminalFocusController? = nil
  var chatId: UUID? = nil

  var body: some View {
    let draft = controller.questionDraft(for: request)
    QuestionPickerContent(
      draft: draft,
      isResolving: didStartResolving || controller.isResolvingQuestion,
      chrome: .composer,
      actions: QuestionPickerActions(
        submit: { resolve { await controller.answerQuestion(answers: draft.answers) } },
        dismiss: { resolve { await controller.cancelQuestion() } },
        answerDirectly: { spec, label in
          resolve { await controller.answerQuestion(answers: [spec.id: QuestionAnswerEntry(answers: [label])]) }
        }
      ),
      focus: focus,
      chatId: chatId
    )
  }

  private func resolve(_ work: @escaping @MainActor () async -> Void) {
    guard !didStartResolving, !controller.isResolvingQuestion else { return }
    didStartResolving = true
    Task {
      await work()
      didStartResolving = false
    }
  }
}
