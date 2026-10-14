import ACPKit
import CodevisorCore
import CodevisorUI
import SwiftUI

struct PlanApprovalQuestionCard: View {
  @Bindable var controller: SessionController
  let question: QuestionSpec
  let maxHeight: CGFloat

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  @Environment(\.theme) private var theme
  @State private var isGivingFeedback = false
  @State private var feedback = ""
  @State private var submittingLabel: String?
  @State private var width: CGFloat = 0
  @FocusState private var isFeedbackFocused: Bool

  private static let stackingWidth: CGFloat = 480
  private static let compactHeight: CGFloat = 220

  private var stacksActions: Bool {
    width > 0 ? width < Self.stackingWidth : horizontalSizeClass == .compact
  }

  private var isCompactWhileTyping: Bool {
    isGivingFeedback && isFeedbackFocused && maxHeight < Self.compactHeight
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      if !isCompactWhileTyping {
        QuestionCardHeader(
          title: isGivingFeedback ? "What should change?" : question.question,
          dismissLabel: "Dismiss plan approval",
          onDismiss: { Task { await controller.cancelQuestion() } }
        )
      }

      if isGivingFeedback {
        feedbackStep
          .transition(.opacity)
      } else {
        actions(primary: implementButton, secondary: keepPlanningButton)
          .transition(.opacity)
      }
    }
    .onGeometryChange(for: CGFloat.self) {
      $0.size.width
    } action: {
      width = $0
    }
    .animation(Motion.quick(reduceMotion: reduceMotion), value: isGivingFeedback)
    .animation(Motion.quick(reduceMotion: reduceMotion), value: isCompactWhileTyping)
    .onChange(of: controller.isResolvingQuestion) { _, resolving in
      if !resolving { submittingLabel = nil }
    }
  }

  @ViewBuilder
  private func actions(primary: some View, secondary: some View) -> some View {
    Group {
      if stacksActions {
        VStack(spacing: 10) {
          primary
          secondary
        }
      } else {
        HStack(spacing: 10) {
          secondary
          primary
        }
      }
    }
    .controlSize(.large)
    .buttonBorderShape(.capsule)
    .font(.body.weight(.semibold))
  }

  private var implementButton: some View {
    primaryButton("Implement Plan", label: QuestionRequest.implementPlanLabel) {
      submit(QuestionRequest.implementPlanLabel)
    }
    .accessibilityHint("Leave plan mode and start building")
  }

  private var keepPlanningButton: some View {
    secondaryButton("Request Changes") {
      feedback = ""
      isGivingFeedback = true
      isFeedbackFocused = true
    }
    .accessibilityHint("Stay in plan mode and optionally say what should change")
  }

  private var feedbackStep: some View {
    let layout =
      isCompactWhileTyping
      ? AnyLayout(HStackLayout(alignment: .center, spacing: 10))
      : AnyLayout(VStackLayout(alignment: .leading, spacing: 14))
    return layout {
      if isCompactWhileTyping {
        Button {
          isFeedbackFocused = false
        } label: {
          Image(systemName: "keyboard.chevron.compact.down")
            .composerCircleActionLabel(.secondary)
        }
        .buttonStyle(.plain)
        .pointerHighlight(Circle())
        .accessibilityLabel("Hide keyboard")
      }
      feedbackField
      if isCompactWhileTyping {
        sendButton
      } else {
        HStack {
          Button {
            isGivingFeedback = false
          } label: {
            Image(systemName: "chevron.left")
              .composerCircleActionLabel(.secondary)
          }
          .buttonStyle(.plain)
          .pointerHighlight(Circle())
          .disabled(controller.isResolvingQuestion)
          .accessibilityLabel("Back")
          .accessibilityHint("Return to the plan decision")
          Spacer(minLength: 0)
          sendButton
        }
      }
    }
  }

  private var feedbackField: some View {
    TextField("Optional feedback for the agent", text: $feedback, axis: .vertical)
      .font(.body)
      .lineLimit(1...5)
      .focused($isFeedbackFocused)
      .padding(.horizontal, 14)
      .padding(.vertical, 12)
      .frame(minHeight: 48)
      .background(
        ComposerCardStyle().insetShape(by: ComposerCardStyle.contentPadding)
          .fill(HierarchicalShapeStyle.quaternary.opacity(0.6))
      )
      .accessibilityLabel("What should change")
  }

  private var sendButton: some View {
    Button(action: submitKeepPlanning) {
      sendLabel
        .composerCircleActionLabel(.primary, isEnabled: !controller.isResolvingQuestion)
    }
    .buttonStyle(.plain)
    .pointerHighlight(Circle())
    .disabled(controller.isResolvingQuestion)
    .accessibilityLabel("Send requested changes")
    .accessibilityHint("Keeps planning with your feedback")
  }

  @ViewBuilder
  private var sendLabel: some View {
    if submittingLabel == QuestionRequest.keepPlanningLabel {
      ProgressView()
        .controlSize(.small)
        .tint(.white)
    } else {
      Image(systemName: "arrow.up")
    }
  }

  private func primaryButton(
    _ title: String, label: String, action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Group {
        if submittingLabel == label {
          ProgressView()
            .tint(.white)
        } else {
          Text(title)
        }
      }
      .frame(maxWidth: .infinity)
      .foregroundStyle(.white)
    }
    .buttonStyle(.borderedProminent)
    .tint(theme.accent)
    .disabled(controller.isResolvingQuestion)
  }

  private func secondaryButton(_ title: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Text(title)
        .frame(maxWidth: .infinity)
    }
    .buttonStyle(.bordered)
    .tint(.secondary)
    .foregroundStyle(.primary)
    .disabled(controller.isResolvingQuestion)
  }

  private func submitKeepPlanning() {
    submit(QuestionRequest.keepPlanningLabel, note: feedback)
  }

  private func submit(_ label: String, note: String = "") {
    guard !controller.isResolvingQuestion else { return }
    let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
    submittingLabel = label
    isFeedbackFocused = false
    Task {
      await controller.answerQuestion(answers: [
        question.id: QuestionAnswerEntry(answers: [label], note: trimmed.isEmpty ? nil : trimmed)
      ])
    }
  }
}
