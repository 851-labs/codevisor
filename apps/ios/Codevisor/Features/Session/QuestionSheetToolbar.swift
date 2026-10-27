import ACPKit
import CodevisorCore
import SwiftUI

struct QuestionSheetToolbar: ToolbarContent {
  struct Actions {
    let close: () -> Void
    let back: () -> Void
    let next: () -> Void
    let submit: () -> Void
    let answerDirectly: (String) -> Void
  }

  let draft: QuestionDraft
  let question: QuestionSpec
  let isSubmitting: Bool
  let actions: Actions

  var body: some ToolbarContent {
    ToolbarItem(placement: .cancellationAction) {
      Button(role: .close, action: actions.close)
    }
    if let backLabel = question.backOptionLabel {
      ToolbarItem(placement: .navigation) {
        Button(backLabel, systemImage: "chevron.backward") { actions.answerDirectly(backLabel) }
      }
    } else if draft.page > 0 {
      ToolbarItem(placement: .navigation) {
        Button("Back", systemImage: "chevron.backward", action: actions.back)
          .accessibilityLabel("Previous question")
      }
    }
    if draft.isLastPage {
      ToolbarItem(placement: .confirmationAction) {
        Button("Submit", role: .confirm, action: actions.submit)
          .disabled(!draft.isSubmittable || isSubmitting)
          .accessibilityLabel(isSubmitting ? "Submitting answers" : "Submit answers")
      }
    } else {
      ToolbarItem(placement: .primaryAction) {
        Button("Next", action: actions.next)
          .accessibilityLabel("Next question")
      }
    }
  }
}
