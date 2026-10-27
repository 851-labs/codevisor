import ACPKit
import CodevisorCore
import CodevisorUI
import SwiftUI

struct QuestionPickerFooter: View {
  let draft: QuestionDraft
  let question: QuestionSpec
  let chrome: QuestionPickerChrome
  let actions: QuestionPickerActions
  let onRevealNote: () -> Void

  var body: some View {
    HStack(spacing: 8) {
      if !draft.showsNoteField(question) {
        QuestionAddNoteButton {
          draft.revealNote(for: question)
          onRevealNote()
        }
      }
      Spacer(minLength: 0)
      switch chrome {
      case .composer:
        QuestionComposerNavigation(draft: draft, question: question, actions: actions)
      case .transcript:
        QuestionTextNavigation(draft: draft, question: question, actions: actions)
      }
    }
  }
}

private struct QuestionAddNoteButton: View {
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Label("Add note", systemImage: "text.bubble")
        .font(.callout.weight(.medium))
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(Capsule().fill(Color.secondary.opacity(0.16)))
        .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .foregroundStyle(.secondary)
    .help("Add a note for the agent")
  }
}

private struct QuestionComposerNavigation: View {
  let draft: QuestionDraft
  let question: QuestionSpec
  let actions: QuestionPickerActions

  var body: some View {
    HStack(spacing: 4) {
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

private struct QuestionTextNavigation: View {
  let draft: QuestionDraft
  let question: QuestionSpec
  let actions: QuestionPickerActions

  var body: some View {
    HStack(spacing: 6) {
      if let backOptionLabel = question.backOptionLabel {
        Button("Back") { actions.answerDirectly(question, backOptionLabel) }
      } else if draft.page > 0 {
        Button {
          draft.move(by: -1)
        } label: {
          Label("Back", systemImage: "chevron.left")
        }
        .help("Previous question (←)")
      }
      if draft.isLastPage {
        Button(draft.pageCount > 1 ? "Submit Answers" : "Submit", action: actions.submit)
          .buttonStyle(.borderedProminent)
          .disabled(!draft.isSubmittable)
          .keyboardShortcut(.defaultAction)
          .help(draft.isSubmittable ? "Submit (↩)" : "Choose an answer first")
      } else {
        Button {
          draft.move(by: 1)
        } label: {
          Label("Next", systemImage: "chevron.right")
            .labelStyle(.titleAndIcon)
        }
        .help("Next question (→)")
      }
    }
    .controlSize(.regular)
    .buttonBorderShape(.capsule)
  }
}
