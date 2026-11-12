import CodevisorCore
import CodevisorUI
import SwiftUI

struct SidebarModeMenuItems: View {
  @ClientPreference(SidebarMode.preferenceKey, default: SidebarMode.code) private var storedMode

  var body: some View {
    ForEach(SidebarMode.allCases, id: \.self) { mode in
      ShortcutButton(SidebarModeShortcut.id(for: mode)) { storedMode = mode }
    }
    Divider()
  }
}
