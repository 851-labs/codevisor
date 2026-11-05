import CodevisorCore
import CodevisorUI
import SwiftUI

struct NewBotMenuItem: View {
  @FocusedValue(\.rootSidebarActions) private var actions
  @ClientPreference(FeatureFlag.bots.preferenceKey, default: false) private var botsEnabled

  var body: some View {
    if botsEnabled {
      ShortcutButton(.newBot) { actions?.newBot?() }
        .disabled(actions?.newBot == nil)
    }
  }
}
