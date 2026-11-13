import SwiftUI

struct SidebarLeadingToolbarItems: ToolbarContent {
  let sidebar: SidebarVisibilityToggle

  var body: some ToolbarContent {
    ToolbarItem { SidebarToggleToolbarButton(sidebar: sidebar) }
    ToolbarItem { SidebarHistoryToolbarButtons() }
  }
}
