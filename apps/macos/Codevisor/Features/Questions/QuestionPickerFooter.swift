import ACPKit
import CodevisorCore
import SwiftUI

struct QuestionPickerFooter: View {
  let draft: QuestionDraft
  let question: QuestionSpec
  let actions: QuestionPickerActions

  var body: some View {
    HStack(spacing: 4) {
      Spacer(minLength: 0)
      if let backOptionLabel = question.backOptionLabel {
        ComposerNavigationButton(systemImage: "arrow.left", help: "Back", accessibilityLabel: "Back") {
          actions.answerDirectly(question, backOptionLabel)
        }
      }
      if draft.page > 0 {
        ComposerNavigationButton(
          systemImage: "arrow.left", help: "Previous question (←)", accessibilityLabel: "Previous question"
        ) {
          draft.move(by: -1)
        }
      }
      if draft.isLastPage {
        ComposerSubmitButton(
          isEnabled: draft.isSubmittable,
          help: draft.isSubmittable ? "Submit answers (↩)" : "Choose an answer first",
          accessibilityLabel: "Submit answers",
          action: actions.submit
        )
      } else {
        ComposerNavigationButton(
          systemImage: "arrow.right", help: "Next question (→)", accessibilityLabel: "Next question"
        ) {
          draft.move(by: 1)
        }
      }
    }
  }
}
