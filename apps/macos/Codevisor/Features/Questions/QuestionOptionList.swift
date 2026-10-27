import ACPKit
import CodevisorCore
import CodevisorUI
import SwiftUI

struct QuestionOptionList: View {
  let draft: QuestionDraft
  let question: QuestionSpec
  @Binding var highlighted: Int
  let showsHighlight: Bool
  let focusTargets: QuestionPickerFocusTargets
  let onSubmit: () -> Void

  @State private var infoOption: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      ForEach(Array(question.options.enumerated()), id: \.element.id) { index, option in
        QuestionOptionRow(
          label: displayLabel(option.label),
          info: option.description.flatMap { $0.isEmpty ? nil : $0 },
          isSelected: draft.isSelected(option.label, in: question),
          isHighlighted: showsHighlight && index == highlighted,
          infoOption: $infoOption,
          infoKey: "\(question.id)/\(index)"
        ) {
          choose(option.label, at: index)
        }
      }
      if question.allowsOther, draft.isOtherSelected(question) {
        QuestionOtherAnswerRow(
          draft: draft, question: question, focusTargets: focusTargets, onSubmit: onSubmit
        ) {
          choose(QuestionDraft.otherToken, at: question.options.count)
        }
      } else if question.allowsOther {
        QuestionOptionRow(
          label: "Other",
          info: nil,
          isSelected: false,
          isHighlighted: showsHighlight && highlighted == question.options.count,
          infoOption: $infoOption,
          infoKey: "\(question.id)/other"
        ) {
          choose(QuestionDraft.otherToken, at: question.options.count)
          focusTargets.focusAnswerEditorWhenReady()
        }
      }
    }
    .onChange(of: infoOption) { _, shown in
      if shown == nil { focusTargets.focusPicker() }
    }
  }

  private func choose(_ token: String, at index: Int) {
    highlighted = index
    draft.toggle(token, in: question)
    if token != QuestionDraft.otherToken { focusTargets.focusPicker() }
  }

  private func displayLabel(_ label: String) -> String {
    guard question.id == QuestionRequest.exitPlanModeId else { return label }
    switch label {
    case QuestionRequest.implementPlanLabel: return "Implement Plan"
    case QuestionRequest.keepPlanningLabel: return "Request Changes"
    default: return label
    }
  }
}

private struct QuestionOptionRow: View {
  let label: String
  let info: String?
  let isSelected: Bool
  let isHighlighted: Bool
  @Binding var infoOption: String?
  let infoKey: String
  let action: () -> Void

  var body: some View {
    HStack(spacing: 0) {
      Button(action: action) {
        HStack(spacing: 10) {
          Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .font(.caption)
            .foregroundStyle(indicatorStyle)
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
        QuestionOptionInfoButton(title: label, info: info, isHighlighted: isHighlighted, showsInfo: showsInfo)
          .padding(.trailing, 6)
      }
    }
    .background(RoundedRectangle(cornerRadius: 6).fill(fillStyle))
    .contentShape(RoundedRectangle(cornerRadius: 6))
  }

  private var showsInfo: Binding<Bool> {
    Binding(
      get: { infoOption == infoKey },
      set: { isShowing in
        if isShowing {
          infoOption = infoKey
        } else if infoOption == infoKey {
          infoOption = nil
        }
      }
    )
  }

  private var indicatorStyle: AnyShapeStyle {
    if isHighlighted { return AnyShapeStyle(.white) }
    return isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary)
  }

  private var fillStyle: AnyShapeStyle {
    if isHighlighted { return AnyShapeStyle(Color.accentColor) }
    return isSelected ? AnyShapeStyle(Color.primary.opacity(0.14)) : AnyShapeStyle(Color.clear)
  }
}

private struct QuestionOtherAnswerRow: View {
  let draft: QuestionDraft
  let question: QuestionSpec
  let focusTargets: QuestionPickerFocusTargets
  let onSubmit: () -> Void
  let onDeselect: () -> Void

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Button(action: onDeselect) {
        Image(systemName: "checkmark.circle.fill")
          .font(.caption)
          .foregroundStyle(Color.accentColor)
          .padding(.top, 7)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Other")
      .accessibilityAddTraits(.isSelected)
      QuestionAnswerEditor(
        draft: draft, question: question, placeholder: "Type your answer",
        focusTargets: focusTargets, onSubmit: onSubmit
      )
      .accessibilityLabel("Your answer")
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 1)
    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.08)))
    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor.opacity(0.6), lineWidth: 1))
    .contentShape(RoundedRectangle(cornerRadius: 6))
    .onTapGesture { focusTargets.focusAnswerEditor() }
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
        .foregroundStyle(iconStyle)
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

  private var iconStyle: AnyShapeStyle {
    if isHighlighted { return AnyShapeStyle(.white.opacity(0.85)) }
    return showsInfo ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary)
  }
}
