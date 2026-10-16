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
          description: "Answer in your own words below.",
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
    return Button {
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
        if let description, !description.isEmpty {
          Text(description)
            .lineLimit(1)
            .foregroundStyle(
              isHighlighted ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.secondary))
        }
        Spacer(minLength: 0)
        if index < 9 {
          Text("\(index + 1)")
            .font(.caption2.monospacedDigit())
            .foregroundStyle(
              isHighlighted ? AnyShapeStyle(.white.opacity(0.7)) : AnyShapeStyle(.quaternary))
        }
      }
      .foregroundStyle(isHighlighted ? Color.white : Color.primary)
      .padding(.horizontal, 10)
      .padding(.vertical, 6)
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
    .buttonStyle(.plain)
    .accessibilityLabel(label + (description.map { ", \($0)" } ?? ""))
    .accessibilityAddTraits(isSelected ? .isSelected : [])
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
