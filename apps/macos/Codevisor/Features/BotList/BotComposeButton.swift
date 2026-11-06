import CodevisorUI
import SwiftUI

struct BotComposeButton: View {
  let onNewBot: () -> Void

  var body: some View {
    Button(action: onNewBot) { Label("New Bot", symbol: .mascotBadgePlus) }
      .labelStyle(.iconOnly)
      .help("New Bot")
  }
}
