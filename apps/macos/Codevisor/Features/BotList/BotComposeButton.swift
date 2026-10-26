import SwiftUI

struct BotComposeButton: View {
  let canCreateBots: Bool
  let onNewBot: () -> Void

  var body: some View {
    Button("New Bot", systemImage: "square.and.pencil", action: onNewBot)
      .labelStyle(.iconOnly)
      .disabled(!canCreateBots)
      .help(canCreateBots ? "New Bot" : "Connect a machine that supports bots to create one")
  }
}
