import SwiftUI

struct BotListEmptyDetail: View {
  @FocusedValue(\.botListActions) private var actions

  var body: some View {
    ContentUnavailableView {
      Label("No Bot Selected", systemImage: "bubble.left.and.bubble.right")
    } description: {
      Text("Choose a bot from the sidebar to continue the conversation.")
    } actions: {
      if let newBot = actions?.newBot {
        Button("New Bot", action: newBot)
      }
    }
  }
}
