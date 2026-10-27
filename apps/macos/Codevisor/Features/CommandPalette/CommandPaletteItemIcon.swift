import Autocomplete
import SwiftUI

struct CommandPaletteItemIcon: View {
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
    case let .workspace(icon):
      SidebarWorkspaceLeadingIcon(
        icon: icon, store: store, color: highlightColor ?? .secondary, statusColor: highlightColor)
    }
  }
}
