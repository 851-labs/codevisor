import CodevisorCore
import CodevisorUI
import SwiftUI

struct NewBotMenuItem: View {
  @FocusedValue(\.rootSidebarActions) private var actions

  var body: some View {
    ShortcutButton(.newBot) { actions?.newBot() }
      .disabled(actions == nil)
  }
}
