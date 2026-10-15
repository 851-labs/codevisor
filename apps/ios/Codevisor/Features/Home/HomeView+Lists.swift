import CodevisorCore
import CodevisorUI
import SwiftUI

extension HomeView {
  @ViewBuilder
  var refreshableNavigationContent: some View {
    switch launch {
    case .content:
      sidebarList
    case .empty, .onboarding:
      refreshableState(allowsStateHitTesting: false) {
        emptyState
      }
    case .loading:
      refreshableState(allowsStateHitTesting: false) {
        HomeNavigationSyncView(state: .loading(machineName: "your machines"))
      }
    }
  }

  private var sidebarList: some View {
    sidebarActionHandler.actions = sidebarActions
    return HomeSidebarLiveList(
      actions: sidebarActionHandler,
      splitNavigation: layoutMode == .split ? navigation : nil,
      gitLookups: sidebarGitLookups
    )
  }

  #if DEBUG
    var sampleSidebar: some View {
      HomeSidebarSampleData.Sidebar(isSelectable: layoutMode == .split)
    }
  #endif

  var emptyState: some View {
    Text("No Workspaces")
      .font(.title3.weight(.bold))
      .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
