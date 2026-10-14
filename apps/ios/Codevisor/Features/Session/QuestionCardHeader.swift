import CodevisorUI
import SwiftUI

struct QuestionCardHeader: View {
  let title: String
  var lineLimit: Int?
  let dismissLabel: String
  let onDismiss: () -> Void

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Text(title)
        .font(.headline)
        .lineLimit(lineLimit)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentTransition(.opacity)
        .padding(.top, 4)
        .accessibilityAddTraits(.isHeader)
      Button(action: onDismiss) {
        Image(systemName: "xmark")
          .composerCircleActionLabel(.secondary)
      }
      .buttonStyle(.plain)
      .pointerHighlight(Circle())
      .accessibilityLabel(dismissLabel)
    }
  }
}
