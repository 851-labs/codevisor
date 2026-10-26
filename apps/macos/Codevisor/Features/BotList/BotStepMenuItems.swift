import SwiftUI

struct BotStepMenuItems: View {
  @FocusedValue(\.botListActions) private var actions

  var body: some View {
    ShortcutButton(.previousWorkspace, title: "Previous Bot") { actions?.stepBot(-1) }
      .disabled(actions == nil)
    ShortcutButton(.nextWorkspace, title: "Next Bot") { actions?.stepBot(1) }
      .disabled(actions == nil)
  }
}
