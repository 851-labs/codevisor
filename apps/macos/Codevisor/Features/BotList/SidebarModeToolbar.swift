import CodevisorCore
import CodevisorUI
import SwiftUI

struct SidebarModeToolbar: ViewModifier {
  let isDrawer: Bool
  @Environment(AdaptivePanelLayout.self) private var panelLayout
  @ClientPreference(SidebarMode.preferenceKey, default: SidebarMode.code) private var storedMode
  @ClientPreference(RootSidebarVisibility.collapsedKey, default: false) private var sidebarCollapsed

  func body(content: Content) -> some View {
    content
      .toolbar {
        if showsModePicker {
          ToolbarItem {
            SidebarModePicker(mode: $storedMode, help: SidebarModeShortcut.help)
          }
        }
      }
  }

  private var showsModePicker: Bool {
    !isDrawer && panelLayout.docksSidebar && !sidebarCollapsed
  }
}
