import ACPKit
import CodevisorCore
import CodevisorUI
import SwiftUI

/// The "implement this plan?" decision as its own presentation instead of a
/// generic two-option picker: a binary choice reads best as two buttons, and
/// the common answer — Implement — is one tap.
///
/// Progressively disclosed feedback: "Request Changes" turns the card into a
/// "What should change?" step — a multi-line field with the composer's own
/// back and send buttons beneath it — so refinement notes are there when
/// wanted without cluttering the decision. Sending it empty just keeps planning. Both
/// harness paths carry the note to the model (Claude's ExitPlanMode denial
/// and Codex's follow-up message).
///
/// The decision's actions sit side by side where there's room and stack
/// full width on narrow cards (a phone in portrait), primary on top as in
/// stacked alerts.
struct PlanApprovalQuestionCard: View {
  @Bindable var controller: SessionController
  let question: QuestionSpec
  /// The tallest the card's content may be (keyboard-aware; see
  /// `QuestionCardView.maxHeight`).
  let maxHeight: CGFloat

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  @Environment(\.theme) private var theme
  @State private var isGivingFeedback = false
  @State private var feedback = ""
  /// Which choice is being sent, so its button (not the card) shows progress.
  @State private var submittingLabel: String?
  /// Measured card width; decides side-by-side vs stacked actions. Stacking
  /// only changes height, so this can't feed back into the width.
  @State private var width: CGFloat = 0
  @FocusState private var isFeedbackFocused: Bool

  /// Below this width two capsules side by side get cramped.
  private static let stackingWidth: CGFloat = 480
  /// Below this offered height (a phone in landscape with the keyboard up)
  /// the feedback step collapses to its field and send button.
  private static let compactHeight: CGFloat = 220

  /// Until the width is measured, guess from the size class so the first
  /// frame already has the right shape. Growing the card a frame after it
  /// appears (side by side → stacked) happened after the transcript had
  /// settled at idle, and the taller card then covered the plan.
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
      // A failed submission leaves the card up; let the user retry.
      if !resolving { submittingLabel = nil }
    }
  }

  /// Primary on top when stacked, trailing when side by side.
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

  // MARK: - Decision

  private var implementButton: some View {
    primaryButton("Implement Plan", label: QuestionRequest.implementPlanLabel) {
      submit(QuestionRequest.implementPlanLabel)
    }
    .accessibilityHint("Leave plan mode and start building")
  }

  private var keepPlanningButton: some View {
    secondaryButton("Request Changes") {
      // Start empty; clearing on entry (not on Back) also discards any
      // autocorrection committed as the previous field went away.
      feedback = ""
      isGivingFeedback = true
      isFeedbackFocused = true
    }
    .accessibilityHint("Stay in plan mode and optionally say what should change")
  }

  // MARK: - Feedback

  private var feedbackStep: some View {
    // AnyLayout keeps the field's identity (focus, keyboard) when the
    // step collapses to one row.
    let layout =
      isCompactWhileTyping
      ? AnyLayout(HStackLayout(alignment: .center, spacing: 10))
      : AnyLayout(VStackLayout(alignment: .leading, spacing: 14))
    return layout {
      if isCompactWhileTyping {
        // The way back to the full step (and its Back button).
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
        // The composer's own footer: back on the leading edge, send on the
        // trailing edge, so writing feedback feels like writing a message.
        HStack {
          Button {
            // Only change the step. Resigning focus here first made the
            // keyboard commit a pending autocorrection, whose text write
            // raced this tap and could swallow it; removing the field
            // drops focus on its own.
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
      // Return inserts a newline, like the composer; the send button
      // sends.
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

  // MARK: - Buttons

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
      // An ancestor's foreground style overrides the prominent style's
      // white label, leaving dark text on the accent.
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
    // Neutral gray, so only the primary action carries the accent.
    .tint(.secondary)
    .foregroundStyle(.primary)
    .disabled(controller.isResolvingQuestion)
  }

  // MARK: - Submit

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
