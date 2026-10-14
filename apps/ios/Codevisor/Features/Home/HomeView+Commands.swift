import CodevisorCore
import SwiftUI

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

  func toggleSidebar() {
    guard layoutMode == .split else { return }
    sidebarAutoCollapsed = false
    withAnimation(.smooth(duration: 0.3)) {
      sidebarColumnVisibility = sidebarColumnVisibility == .detailOnly ? .doubleColumn : .detailOnly
    }
  }
}
