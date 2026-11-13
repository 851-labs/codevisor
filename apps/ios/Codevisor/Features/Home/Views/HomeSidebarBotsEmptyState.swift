import CodevisorUI
import SwiftUI

struct HomeSidebarBotsEmptyState: View {
  let onNewBot: () -> Void

  var body: some View {
    ContentUnavailableView {
      Label {
        Text(BotListEmptyCopy.title)
      } icon: {
        CodevisorSymbol.mascot.image
          .font(.system(size: 36))
          .foregroundStyle(.tertiary)
      }
    } description: {
      Text(BotListEmptyCopy.message)
    } actions: {
      newBotButton
    }
  }

  private var newBotButton: some View {
    Button(action: onNewBot) {
      Text("New Bot")
        .font(.body.weight(.semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
    }
    .buttonStyle(.borderedProminent)
    .buttonBorderShape(.capsule)
    .accessibilityIdentifier("sidebar.emptyNewBot")
  }
}
