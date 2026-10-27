import ACPKit
import CodevisorCore
import CodevisorUI
import SwiftUI

struct QuestionOtherRow: View {
  let draft: QuestionDraft
  let question: QuestionSpec
  let indicator: QuestionOptionIndicator
  let focusRequest: UUID?
  let onToggle: () -> Void
  let onFocusChange: (Bool) -> Void
  let onHeightChange: () -> Void

  var body: some View {
    if draft.isOtherSelected(question) {
      QuestionOtherEditorRow(
        draft: draft, question: question, indicator: indicator, focusRequest: focusRequest,
        onToggle: onToggle, onFocusChange: onFocusChange, onHeightChange: onHeightChange
      )
    } else {
      QuestionOptionRow(title: "Other", description: nil, indicator: indicator, isSelected: false, action: onToggle)
        .accessibilityHint("Type your own answer")
    }
  }
}

private struct QuestionOtherEditorRow: View {
  let draft: QuestionDraft
  let question: QuestionSpec
  let indicator: QuestionOptionIndicator
  let focusRequest: UUID?
  let onToggle: () -> Void
  let onFocusChange: (Bool) -> Void
  let onHeightChange: () -> Void

  @State private var selection = NSRange(location: 0, length: 0)
  @State private var textHeight: CGFloat = 0

  private static let minEditorHeight: CGFloat = 28
  private static let maxEditorHeight: CGFloat = 140
  private static let ringWidth: CGFloat = 1.5
  private let cardStyle = ComposerCardStyle()

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Button(action: onToggle) {
        Image(systemName: indicator == .multiple ? "checkmark.square.fill" : "checkmark.circle.fill")
          .font(.title3)
          .foregroundStyle(Color.accentColor)
          .frame(width: 24, height: Self.minEditorHeight)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Other")
      .accessibilityAddTraits(.isSelected)
      ZStack(alignment: .topLeading) {
        editor
        if draft.typedAnswer(for: question).isEmpty {
          Text("Your answer")
            .font(.body)
            .foregroundStyle(.tertiary)
            .padding(.top, 4)
            .allowsHitTesting(false)
        }
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 12)
    .background(cardStyle.insetShape(by: ComposerCardStyle.contentPadding).fill(Color.accentColor.opacity(0.14)))
    .overlay(
      cardStyle.insetShape(by: ComposerCardStyle.contentPadding + Self.ringWidth / 2)
        .stroke(Color.accentColor.opacity(0.55), lineWidth: Self.ringWidth)
        .padding(Self.ringWidth / 2)
    )
    .onChange(of: textHeight) { _, _ in onHeightChange() }
  }

  private var editor: some View {
    ComposerTextView(
      text: Binding(get: { draft.typedAnswer(for: question) }, set: { draft.setTypedAnswer($0, for: question) }),
      selection: $selection,
      handoffID: nil,
      handoffRole: .none,
      isEditable: true,
      focusRequest: focusRequest,
      onPasteAttachmentEvent: { _ in },
      isComposerExpanded: false,
      contentHeight: $textHeight,
      onFocusChange: onFocusChange,
      onResizePanChanged: { _ in },
      onResizePanEnded: { _, _ in },
      onResizePanCancelled: {},
      topInset: 0
    )
    .frame(height: min(max(textHeight, Self.minEditorHeight), Self.maxEditorHeight))
    .accessibilityLabel("Your answer")
  }
}
