import CodevisorUI
import SwiftUI

struct BotComposeButton: View {
  let canCreateBots: Bool
  let onNewBot: () -> Void

  var body: some View {
    Button(action: onNewBot) { Label("New Bot", symbol: .mascotBadgePlus) }
      .labelStyle(.iconOnly)
      .disabled(!canCreateBots)
      .help(canCreateBots ? "New Bot" : "Connect a machine that supports bots to create one")
  }
}
