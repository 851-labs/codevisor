import SwiftUI

struct CommandPaletteItemIcon: View {
  let icon: CommandPaletteItem.Icon
  let store: SessionStore?

  var body: some View {
    switch icon {
    case let .symbol(name):
      Image(systemName: name)
    case let .workspace(icon):
      SidebarWorkspaceLeadingIcon(icon: icon, store: store)
    }
  }
}
