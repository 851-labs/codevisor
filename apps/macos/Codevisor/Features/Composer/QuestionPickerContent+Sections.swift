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
          label: option.label,
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
      // Mouse interaction makes the picker the keyboard target too,
      // so a follow-up Return/arrow works no matter where focus was.
      // Choosing "Other" goes straight to its answer field instead.
      if index >= question.options.count,
        selections[question.id, default: []].contains(Self.otherToken)
      {
        focusNotes()
      } else {
        focusPicker()
      }
    } label: {
      // Same selection language as the slash-command menu in this
      // card: the keyboard highlight is an accent pill with white
      // content; a committed selection that ISN'T highlighted keeps a
      // quiet themed fill (multi-select stays legible at a glance)
      // with an accent checkmark.
      HStack(spacing: 10) {
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
          .font(.caption)
          .foregroundStyle(
            isHighlighted
              ? AnyShapeStyle(.white)
              : isSelected ? AnyShapeStyle(theme.accent) : AnyShapeStyle(.tertiary)
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
              ? AnyShapeStyle(theme.accent)
              : isSelected
                ? AnyShapeStyle(theme.rowSelectedBackground)
                : AnyShapeStyle(Color.clear)
          )
      )
      .contentShape(RoundedRectangle(cornerRadius: 6))
    }
    .buttonStyle(.plain)
    .accessibilityLabel(label + (description.map { ", \($0)" } ?? ""))
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }

  /// The same auto-resizing editor as the composer, boxed so it reads as a
  /// field inside the picker. Always mounted — no layout shift on "Other".
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
          // Escape hops focus back to the option list; a second
          // Escape there dismisses the question.
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
    // Themed input-field chrome: quiet card fill on the glass, themed
    // border — accented while "Other" makes this field the answer.
    .background(RoundedRectangle(cornerRadius: 8).fill(theme.cardQuietBackground))
    .overlay(
      RoundedRectangle(cornerRadius: 8)
        .strokeBorder(
          isOtherSelected ? theme.accent : theme.border,
          lineWidth: 1
        )
    )
  }

  func footer(_ question: QuestionSpec) -> some View {
    HStack(spacing: 8) {
      Text(
        question.multiSelect == true
          ? "Space toggles · Return continues · Esc dismisses"
          : "↑↓ and 1-9 select · Return continues · Esc dismisses"
      )
      .font(.caption2)
      .foregroundStyle(.tertiary)
      Spacer()
      // Action buttons cluster tighter than the hint text.
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
          // More questions ahead: advance instead of submitting.
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
