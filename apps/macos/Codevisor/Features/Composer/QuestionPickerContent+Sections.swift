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
      if question.allowsOther {
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
        if index >= question.options.count,
          selections[question.id, default: []].contains(Self.otherToken)
        {
          focusNotes()
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
    .foregroundStyle(isHighlighted ? Color.white : Color.primary)
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

  func notesEditor(_ question: QuestionSpec) -> some View {
    let isOtherSelected = selections[question.id, default: []].contains(Self.otherToken)
    return ZStack(alignment: .topLeading) {
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
        onTextViewReady: { textView in
          anchor.notesEditor = textView
        }
      )
      .frame(height: notesHeight)
      if (notes[question.id] ?? "").isEmpty {
        Text(isOtherSelected ? "Type your answer (required)" : "Add a note (optional)")
          .foregroundStyle(.tertiary)
          .padding(.top, 6)
          .allowsHitTesting(false)
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 2)
    .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
    .overlay(
      RoundedRectangle(cornerRadius: 8)
        .strokeBorder(
          isOtherSelected ? Color.accentColor : Color.separatorColor,
          lineWidth: 1
        )
    )
  }

  func footer(_ question: QuestionSpec) -> some View {
    HStack(spacing: 8) {
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
          let isBrowserChoice = question.presentation == .browserChoice
          ComposerSubmitButton(
            systemImage: isBrowserChoice ? "arrow.right" : "arrow.up",
            isEnabled: isSubmittable,
            help: isSubmittable
              ? isBrowserChoice ? "Continue (↩)" : "Submit answers (↩)"
              : isBrowserChoice
                ? "Choose a browser to continue"
                : "\"Other\" needs an answer below",
            accessibilityLabel: isBrowserChoice ? "Continue" : "Submit answers"
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
