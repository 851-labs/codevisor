import SwiftUI

struct BotConversationHeaderName: View {
  let name: String

  var body: some View {
    HStack(spacing: 3) {
      Text(name)
        .font(.headline)
        .lineLimit(1)
      Image(systemName: "chevron.compact.forward")
        .font(.subheadline.weight(.bold))
        .foregroundStyle(.tertiary)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 5)
    .glassEffect(.regular.interactive(), in: .capsule)
  }
}
