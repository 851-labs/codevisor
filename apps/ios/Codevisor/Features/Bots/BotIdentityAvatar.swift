import CodevisorCore
import SwiftUI

struct BotIdentityAvatar: View {
  let editor: BotEditorModel
  let size: CGFloat
  let edit: () -> Void

  var body: some View {
    if editor.mascot != nil, editor.mascotOptions != nil {
      Button(action: edit) {
        VStack(spacing: 8) {
          avatar
          Text("Edit")
            .font(.subheadline)
            .foregroundStyle(.tint)
        }
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Edit Mascot")
    } else {
      avatar
    }
  }

  private var avatar: some View {
    BotAvatar(mascot: editor.mascot, serverId: editor.serverId, symbolName: editor.symbolName, size: size)
  }
}
