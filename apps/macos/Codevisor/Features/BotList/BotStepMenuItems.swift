import SwiftUI

struct BotStepMenuItems: View {
  @FocusedValue(\.botListActions) private var actions

  var body: some View {
    ShortcutButton(.previousTab, title: "Previous Bot") { actions?.stepBot(-1) }
      .disabled(actions == nil)
    ShortcutButton(.nextTab, title: "Next Bot") { actions?.stepBot(1) }
      .disabled(actions == nil)
  }
}
