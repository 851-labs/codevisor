import SwiftUI

struct BotListEmptyDetail: View {
  let onNewBot: () -> Void

  var body: some View {
    ContentUnavailableView {
      Label("No Bot Selected", systemImage: "bubble.left.and.bubble.right")
    } description: {
      Text("Choose a bot from the sidebar to continue the conversation.")
    } actions: {
      Button("New Bot", action: onNewBot)
    }
  }
}
