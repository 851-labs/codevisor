import CodevisorCore
import CodevisorUI
import SwiftUI

struct SidebarModeCommands: Commands {
  var body: some Commands {
    CommandGroup(before: .sidebar) {
      SidebarModeMenuItems()
    }
  }
}

private struct SidebarModeMenuItems: View {
  @ClientPreference(FeatureFlag.bots.preferenceKey, default: false) private var botsEnabled
  @ClientPreference(SidebarMode.preferenceKey, default: SidebarMode.code) private var storedMode

  var body: some View {
    if botsEnabled {
      ForEach(SidebarMode.allCases, id: \.self) { mode in
        ShortcutButton(SidebarModeShortcut.id(for: mode)) { storedMode = mode }
      }
      Divider()
    }
  }
}
