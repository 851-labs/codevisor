import SwiftUI

struct BotConversationTitleLine: View {
  let name: String

  var body: some View {
    Text(name)
      .font(.body.weight(.semibold))
      .foregroundStyle(.primary)
      .lineLimit(1)
      .truncationMode(.tail)
  }
}
