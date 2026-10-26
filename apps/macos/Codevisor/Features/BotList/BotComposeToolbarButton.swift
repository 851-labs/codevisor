import SwiftUI

struct BotComposeToolbarButton: View {
  @FocusedValue(\.botListActions) private var actions

  var body: some View {
    BotComposeButton(canCreateBots: actions?.newBot != nil, onNewBot: { actions?.newBot?() })
  }
}
