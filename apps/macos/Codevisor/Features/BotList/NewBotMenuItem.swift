import SwiftUI

struct NewBotMenuItem: View {
  @FocusedValue(\.botListActions) private var actions

  var body: some View {
    ShortcutButton(.newChat, title: "New Bot") { actions?.newBot?() }
      .disabled(actions?.newBot == nil)
  }
}
