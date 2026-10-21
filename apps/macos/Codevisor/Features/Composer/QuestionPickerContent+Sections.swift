import SwiftUI
import AppKit
import CodevisorCore
import ACPKit
import CodevisorUI

extension QuestionPickerContent {
  private var dismissButton: some View {
    Button {
      cancel()
    } label: {
      Image(systemName: "xmark")
        .font(.caption)
        .frame(width: 20, height: 20)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .foregroundStyle(.secondary)
    .help("Dismiss without answering (Esc)")
    .accessibilityLabel("Dismiss without answering")
    .accessibilityHint("Keyboard shortcut: Escape")
  }

  func header(_ question: QuestionSpec) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text(question.question)
        .font(.callout.weight(.medium))
      Spacer(minLength: 0)
      dismissButton
    }
  }

  func optionList(_ question: QuestionSpec) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      ForEach(Array(question.options.enumerated()), id: \.element.id) { index, option in
        optionRow(
          question,
          index: index,
          label: displayLabel(option.label, in: question),
          description: option.description,
          isSelected: selections[question.id, default: []].contains(option.label)
        )
      }
      if question.allowsOther, isOtherSelected(question) {
        otherAnswerRow(question)
      } else if question.allowsOther {
        optionRow(
          question,
          index: question.options.count,
          label: "Other",
          description: nil,
          isSelected: selections[question.id, default: []].contains(Self.otherToken)
        )
      }
    }
  }

  private func displayLabel(_ label: String, in question: QuestionSpec) -> String {
    guard question.id == QuestionRequest.exitPlanModeId else { return label }
    switch label {
    case QuestionRequest.implementPlanLabel: return "Implement Plan"
    case QuestionRequest.keepPlanningLabel: return "Request Changes"
    default: return label
    }
  }

  private func optionRow(
    _ question: QuestionSpec,
    index: Int,
    label: String,
    description: String?,
    isSelected: Bool
  ) -> some View {
    let isHighlighted = index == highlighted
    let info = description.flatMap { $0.isEmpty ? nil : $0 }
    return HStack(spacing: 0) {
      Button {
        highlighted = index
        activate(question, index: index)
        if index >= question.options.count, isOtherSelected(question) {
          anchor.focusesNotesWhenReady = true
        } else {
          focusPicker()
        }
      } label: {
        HStack(spacing: 10) {
          Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .font(.caption)
            .foregroundStyle(
              isHighlighted
                ? AnyShapeStyle(.white)
                : isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary)
            )
          Text(label)
            .fontWeight(.medium)
            .multilineTextAlignment(.leading)
          Spacer(minLength: 0)
        }
        .foregroundStyle(isHighlighted ? Color.white : Color.primary)
        .padding(.leading, 10)
        .padding(.trailing, info == nil ? 10 : 4)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel(label)
      .accessibilityHint(info ?? "")
      .accessibilityAddTraits(isSelected ? .isSelected : [])
      if let info {
        QuestionOptionInfoButton(
          title: label,
          info: info,
          isHighlighted: isHighlighted,
          showsInfo: infoBinding("\(question.id)/\(index)")
        )
        .padding(.trailing, 6)
      }
    }
    .background(
      RoundedRectangle(cornerRadius: 6)
        .fill(
          isHighlighted
            ? AnyShapeStyle(Color.accentColor)
            : isSelected
              ? AnyShapeStyle(Color.primary.opacity(0.14))
              : AnyShapeStyle(Color.clear)
        )
    )
    .contentShape(RoundedRectangle(cornerRadius: 6))
  }

  private func infoBinding(_ key: String) -> Binding<Bool> {
    Binding(
      get: { infoOption == key },
      set: { isShowing in
        if isShowing {
          infoOption = key
        } else if infoOption == key {
          infoOption = nil
          focusPicker()
        }
      }
    )
  }

  private func otherAnswerRow(_ question: QuestionSpec) -> some View {
    HStack(alignment: .top, spacing: 10) {
      Button {
        highlighted = question.options.count
        activate(question, index: question.options.count)
        focusPicker()
      } label: {
        Image(systemName: "checkmark.circle.fill")
          .font(.caption)
          .foregroundStyle(Color.accentColor)
          .padding(.top, 7)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Other")
      .accessibilityAddTraits(.isSelected)
      notesEditor(question, placeholder: "Type your answer")
        .accessibilityLabel("Your answer")
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 1)
    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.08)))
    .overlay(
      RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor.opacity(0.6), lineWidth: 1)
    )
    .contentShape(RoundedRectangle(cornerRadius: 6))
    .onTapGesture { focusNotes() }
  }

  func noteField(_ question: QuestionSpec) -> some View {
    notesEditor(question, placeholder: "Add a note for the agent")
      .accessibilityLabel("Note")
      .padding(.horizontal, 10)
      .padding(.vertical, 4)
      .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.1)))
  }

  private func addNoteButton(_ question: QuestionSpec) -> some View {
    Button {
      revealNote(question)
    } label: {
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

  private func notesEditor(_ question: QuestionSpec, placeholder: String) -> some View {
    ZStack(alignment: .topLeading) {
      ChatInputEditor(
        text: notesBinding(question),
        calculatedHeight: $notesHeight,
        minHeight: 24,
        maxHeight: 120,
        onSubmit: { advanceOrSubmit() },
        onKeyCommand: { command in
          if command == .dismissSelection {
            focusPicker()
            return true
          }
          return false
        },
        onTextViewReady: { attachNotesEditor($0) }
      )
      .frame(height: notesHeight)
      if (notes[question.id] ?? "").isEmpty {
        Text(placeholder)
          .foregroundStyle(.tertiary)
          .padding(.top, 6)
          .allowsHitTesting(false)
      }
    }
  }

  func footer(_ question: QuestionSpec) -> some View {
    HStack(spacing: 8) {
      if showsAddNoteButton(question) {
        addNoteButton(question)
      }
      Spacer()
      HStack(spacing: 4) {
        if let backOptionLabel = question.backOptionLabel {
          ComposerNavigationButton(
            systemImage: "arrow.left",
            help: "Back",
            accessibilityLabel: "Back"
          ) {
            submitDirectAnswer(question, label: backOptionLabel)
          }
        }
        if questionIndex > 0 {
          ComposerNavigationButton(
            systemImage: "arrow.left",
            help: "Previous question (←)",
            accessibilityLabel: "Previous question"
          ) {
            moveQuestion(-1)
          }
        }
        if !isLastQuestion {
          ComposerNavigationButton(
            systemImage: "arrow.right",
            help: "Next question (→)",
            accessibilityLabel: "Next question"
          ) {
            moveQuestion(1)
          }
        } else {
          ComposerSubmitButton(
            systemImage: "arrow.up",
            isEnabled: isSubmittable,
            help: isSubmittable ? "Submit answers (↩)" : "\"Other\" needs an answer below",
            accessibilityLabel: "Submit answers"
          ) {
            submit()
          }
        }
      }
    }
  }

}

private struct QuestionOptionInfoButton: View {
  let title: String
  let info: String
  let isHighlighted: Bool
  @Binding var showsInfo: Bool

  var body: some View {
    Button {
      showsInfo = true
    } label: {
      Image(systemName: "info.circle")
        .foregroundStyle(
          isHighlighted
            ? AnyShapeStyle(.white.opacity(0.85))
            : showsInfo ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary)
        )
        .frame(width: 20, height: 20)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help(info)
    .accessibilityLabel("About \(title)")
    .popover(isPresented: $showsInfo, arrowEdge: .bottom) {
      Text(info)
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
        .padding(12)
        .frame(idealWidth: 300, maxWidth: 320, alignment: .leading)
    }
  }
}
