import SwiftUI

struct BotConversationTitleLine: View {
  let name: String
  let timestamp: String?

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 6) {
      Text(name)
        .font(.body.weight(.semibold))
        .foregroundStyle(.primary)
        .lineLimit(1)
        .truncationMode(.tail)
      Spacer(minLength: 0)
      if let timestamp {
        Text(timestamp)
          .font(.body)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .fixedSize()
      }
    }
  }
}
