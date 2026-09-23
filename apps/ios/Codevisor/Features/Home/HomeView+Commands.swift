import CodevisorCore
import SwiftUI

/// The menu bar's window-level actions: New Chat, Settings, and the sidebar.
extension HomeView {
  var homeCommandActions: HomeCommandActions {
    HomeCommandActions(
      canCreateChat: showsNewChatButton,
      hasSidebar: layoutMode == .split,
      newChat: { presentNewChat() },
      openSettings: { presentedSettingsDestination = .root },
      toggleSidebar: { toggleSidebar() }
    )
  }

  /// Shows or hides the split sidebar, as the column's own toggle does. An
  /// explicit choice ends any automatic collapse.
  func toggleSidebar() {
    guard layoutMode == .split else { return }
    sidebarAutoCollapsed = false
    withAnimation(.smooth(duration: 0.3)) {
      sidebarColumnVisibility = sidebarColumnVisibility == .detailOnly ? .doubleColumn : .detailOnly
    }
  }
}
