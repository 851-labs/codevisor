import ACPKit
import CodevisorCore
import CodevisorUI
import SwiftUI

struct QuestionPickerHeader: View {
  let draft: QuestionDraft
  let question: QuestionSpec
  let chrome: QuestionPickerChrome
  let onDismiss: () -> Void

  var body: some View {
    switch chrome {
    case .composer:
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        QuestionTitle(text: question.question, weight: .medium)
        Spacer(minLength: 0)
        QuestionDismissButton(action: onDismiss)
      }
    case .transcript:
      VStack(alignment: .leading, spacing: 4) {
        QuestionPageCaption(draft: draft, question: question)
        QuestionTitle(text: question.question, weight: .semibold)
      }
    }
  }
}

private struct QuestionTitle: View {
  let text: String
  let weight: Font.Weight

  var body: some View {
    Text(text)
      .font(.callout.weight(weight))
      .fixedSize(horizontal: false, vertical: true)
      .accessibilityAddTraits(.isHeader)
  }
}

private struct QuestionPageCaption: View {
  let draft: QuestionDraft
  let question: QuestionSpec

  var body: some View {
    Text(caption)
      .font(.caption.weight(.medium))
      .foregroundStyle(.secondary)
  }

  private var caption: String {
    let header = question.header.map { " · \($0)" } ?? ""
    guard draft.pageCount > 1 else { return "Question\(header)" }
    return "Question \(draft.page + 1) of \(draft.pageCount)\(header)"
  }
}

struct QuestionDismissButton: View {
  let action: () -> Void

  var body: some View {
    Button(action: action) {
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
}
