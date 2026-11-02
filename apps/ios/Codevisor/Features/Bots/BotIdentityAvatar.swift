import CodevisorCore
import SwiftUI

struct BotIdentityAvatar: View {
  let editor: BotEditorModel
  let size: CGFloat
  let edit: () -> Void

  var body: some View {
    if editor.mascot != nil, editor.mascotOptions != nil {
      VStack(spacing: 8) {
        Button(action: edit) { avatar }
          .buttonStyle(.plain)
          .accessibilityHidden(true)
        Button("Edit Mascot", action: edit)
          .buttonStyle(.borderless)
          .font(.subheadline)
      }
    } else {
      avatar
    }
  }

  private var avatar: some View {
    BotAvatar(mascot: editor.mascot, serverId: editor.serverId, symbolName: editor.symbolName, size: size)
  }
}
