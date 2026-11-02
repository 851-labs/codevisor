import CodevisorCore
import SwiftUI

struct BotEditableAvatar: View {
  private static let focusRingWidth: CGFloat = 3

  let editor: BotEditorModel
  let size: CGFloat
  let edit: () -> Void

  @State private var isHovering = false
  @FocusState private var isFocused: Bool

  var body: some View {
    if editor.mascot != nil, editor.mascotOptions != nil {
      Button(action: edit) {
        avatar.overlay(alignment: .bottom) {
          if isHovering || isFocused { BotAvatarEditBand(size: size) }
        }
        .clipShape(.circle)
      }
      .buttonStyle(.plain)
      .focused($isFocused)
      .focusEffectDisabled()
      .overlay {
        if isFocused {
          Circle().strokeBorder(.tint, lineWidth: Self.focusRingWidth).padding(-Self.focusRingWidth)
        }
      }
      .onHover { isHovering = $0 }
      .help("Edit Mascot")
      .accessibilityLabel("Edit Mascot")
    } else {
      avatar
    }
  }

  private var avatar: some View {
    BotAvatar(mascot: editor.mascot, serverId: editor.serverId, symbolName: editor.symbolName, size: size)
  }
}
