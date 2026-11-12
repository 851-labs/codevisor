import CodevisorCore
import CodevisorUI
import SwiftUI

struct SidebarModeToolbar: ViewModifier {
  let isDrawer: Bool
  @Environment(AdaptivePanelLayout.self) private var panelLayout
  @ClientPreference(FeatureFlag.bots.preferenceKey, default: false) private var botsEnabled
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
    botsEnabled && !isDrawer && panelLayout.docksSidebar && !sidebarCollapsed
  }
}
