import SwiftUI

struct BotListPlaceholder: View {
  var body: some View {
    VStack(spacing: 6) {
      Text("No Bots Yet")
        .font(.headline)
      Text("Create a bot to start a conversation.")
        .font(.callout)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
    }
    .padding(24)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
