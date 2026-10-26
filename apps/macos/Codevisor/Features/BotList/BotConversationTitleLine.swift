import SwiftUI

struct BotConversationTitleLine: View {
  let name: String
  let timestamp: String?
  let isHighlighted: Bool

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 6) {
      Text(name)
        .font(.body.weight(.semibold))
        .foregroundStyle(isHighlighted ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .lineLimit(1)
        .truncationMode(.tail)
      Spacer(minLength: 0)
      if let timestamp {
        Text(timestamp)
          .font(.subheadline)
          .foregroundStyle(isHighlighted ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.secondary))
          .lineLimit(1)
          .fixedSize()
      }
    }
  }
}
