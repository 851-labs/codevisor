import Autocomplete
import SwiftUI

struct CommandPaletteItemIcon: View {
  private static let botAvatarSize: CGFloat = 18

  let icon: CommandPaletteItem.Icon
  let store: SessionStore?
  @Environment(\.backgroundProminence) private var backgroundProminence
  @Environment(\.autocompleteStyle) private var autocompleteStyle

  private var highlightColor: Color? {
    backgroundProminence == .increased ? autocompleteStyle.itemHighlight.foreground : nil
  }

  var body: some View {
    switch icon {
    case let .symbol(name):
      Image(systemName: name)
    case let .harness(id):
      HarnessIcon(harnessId: id ?? "", fallbackSymbolName: WorkspaceInspectorTab.harness.systemImage)
    case let .bot(bot):
      BotAvatar(bot: bot, size: Self.botAvatarSize)
    case let .workspace(icon):
      SidebarWorkspaceLeadingIcon(
        icon: icon, store: store, color: highlightColor ?? .secondary, statusColor: highlightColor)
    }
  }
}
