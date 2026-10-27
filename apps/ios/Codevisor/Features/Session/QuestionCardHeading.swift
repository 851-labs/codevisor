import ACPKit
import CodevisorCore
import CodevisorUI
import SwiftUI

struct QuestionCardHeading: View {
  let draft: QuestionDraft
  let question: QuestionSpec
  let onSkip: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .center, spacing: 8) {
        Text(caption)
          .font(.footnote.weight(.medium))
          .foregroundStyle(.secondary)
        Spacer(minLength: 0)
        Button("Skip", action: onSkip)
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .buttonStyle(.plain)
          .pointerHighlight(Capsule())
          .accessibilityHint("Skips this question. You can also just type a reply in the message box.")
      }
      Text(question.question)
        .font(.headline)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityAddTraits(.isHeader)
    }
  }

  private var caption: String {
    let header = question.header.map { " · \($0)" } ?? ""
    guard draft.pageCount > 1 else { return "Question\(header)" }
    return "Question \(draft.page + 1) of \(draft.pageCount)\(header)"
  }
}
