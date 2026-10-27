import ACPKit
import CodevisorCore
import CodevisorUI
import SwiftUI

struct QuestionCardFooter: View {
  struct Actions {
    let back: () -> Void
    let next: () -> Void
    let submit: () -> Void
    let answerDirectly: (String) -> Void
  }

  let draft: QuestionDraft
  let question: QuestionSpec
  let isSubmitting: Bool
  let actions: Actions

  var body: some View {
    HStack(spacing: 12) {
      leadingButton
      Spacer(minLength: 0)
      primaryButton
    }
  }

  @ViewBuilder
  private var leadingButton: some View {
    if let backLabel = question.backOptionLabel {
      circleButton("chevron.left", label: backLabel) { actions.answerDirectly(backLabel) }
    } else if draft.page > 0 {
      circleButton("chevron.left", label: "Previous question", action: actions.back)
    }
  }

  @ViewBuilder
  private var primaryButton: some View {
    if draft.isLastPage {
      let canSubmit = draft.isSubmittable && !isSubmitting
      Button(action: actions.submit) {
        Group {
          if isSubmitting {
            ProgressView()
              .controlSize(.small)
              .tint(.white)
          } else {
            Image(systemName: "arrow.up")
          }
        }
        .composerCircleActionLabel(.primary, isEnabled: canSubmit || isSubmitting)
      }
      .buttonStyle(.plain)
      .pointerHighlight(Circle())
      .disabled(!canSubmit)
      .accessibilityLabel(isSubmitting ? "Submitting answers" : "Submit answers")
    } else {
      Button(action: actions.next) {
        Image(systemName: "arrow.right")
          .composerCircleActionLabel(.primary)
      }
      .buttonStyle(.plain)
      .pointerHighlight(Circle())
      .accessibilityLabel("Next question")
    }
  }

  private func circleButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: symbol)
        .composerCircleActionLabel(.secondary)
    }
    .buttonStyle(.plain)
    .pointerHighlight(Circle())
    .accessibilityLabel(label)
  }
}
