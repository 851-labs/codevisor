import CodevisorUI
import SwiftUI

struct HomeSidebarBotsEmptyState: View {
  let canCreateBots: Bool
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
      Text(description)
    } actions: {
      if canCreateBots { newBotButton }
    }
  }

  private var description: String {
    if canCreateBots { BotListEmptyCopy.message } else { "None of your connected machines can run bots right now." }
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
