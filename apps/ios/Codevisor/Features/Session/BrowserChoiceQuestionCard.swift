import ACPKit
import CodevisorCore
import CodevisorUI
import SwiftUI

/// A deterministic browser picker with the same select-then-continue contract
/// as macOS. Browser selection is navigation inside the held tool call, not a
/// chat message, so the primary action uses an explicit Continue label.
struct BrowserChoiceQuestionCard: View {
  @Bindable var controller: SessionController
  let question: QuestionSpec

  @State private var selectedLabel: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      QuestionCardHeader(
        title: question.question,
        dismissLabel: "Dismiss browser choices",
        onDismiss: { Task { await controller.cancelQuestion() } }
      )

      VStack(spacing: 8) {
        ForEach(question.options) { option in
          QuestionOptionRow(
            title: option.label,
            description: option.description,
            indicator: .single,
            isSelected: selectedLabel == option.label,
            action: { selectedLabel = option.label }
          )
        }
      }

      footer
    }
    .sensoryFeedback(.selection, trigger: selectedLabel)
    .animation(.snappy(duration: 0.2), value: selectedLabel)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Choose a browser")
  }

  private var footer: some View {
    HStack {
      Spacer(minLength: 0)
      Button {
        continueWithSelection()
      } label: {
        continueLabel
      }
      .buttonStyle(.plain)
      .pointerHighlight(Circle())
      .disabled(selectedLabel == nil || controller.isResolvingQuestion)
      .accessibilityLabel(controller.isResolvingQuestion ? "Continuing" : "Continue")
      .accessibilityHint("Uses the selected browser for this chat")
    }
  }

  @ViewBuilder
  private var continueLabel: some View {
    if controller.isResolvingQuestion {
      ProgressView()
        .controlSize(.small)
        .composerCircleActionLabel(.primary, isEnabled: false)
    } else {
      Image(systemName: "arrow.right")
        .composerCircleActionLabel(.primary, isEnabled: selectedLabel != nil)
    }
  }

  private func continueWithSelection() {
    guard let selectedLabel, !controller.isResolvingQuestion else { return }
    Task {
      await controller.answerQuestion(answers: [
        question.id: QuestionAnswerEntry(answers: [selectedLabel])
      ])
    }
  }
}
