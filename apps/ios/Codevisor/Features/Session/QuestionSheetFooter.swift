import ACPKit
import CodevisorCore
import CodevisorUI
import SwiftUI

struct QuestionSheetFooter: View {
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
      backButton
      Spacer(minLength: 0)
      primaryButton
    }
  }

  @ViewBuilder
  private var backButton: some View {
    if let backLabel = question.backOptionLabel {
      circleButton("chevron.left", label: backLabel) { actions.answerDirectly(backLabel) }
    } else if draft.page > 0 {
      circleButton("chevron.left", label: "Previous question", action: actions.back)
    }
  }

  @ViewBuilder
  private var primaryButton: some View {
    if draft.isLastPage {
      Button(action: actions.submit) {
        if isSubmitting {
          ProgressView()
        } else {
          Text(draft.pageCount > 1 ? "Submit All" : "Submit")
        }
      }
      .buttonStyle(.borderedProminent)
      .buttonBorderShape(.capsule)
      .controlSize(.large)
      .disabled(!draft.isSubmittable)
      .accessibilityLabel(isSubmitting ? "Submitting answers" : "Submit answers")
    } else {
      Button(action: actions.next) {
        Label("Next", systemImage: "chevron.right")
          .labelStyle(.titleAndIcon)
      }
      .buttonStyle(.bordered)
      .buttonBorderShape(.capsule)
      .controlSize(.large)
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
