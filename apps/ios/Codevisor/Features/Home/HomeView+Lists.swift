import CodevisorCore
import CodevisorUI
import SwiftUI

// MARK: - Lists

extension HomeView {
  /// Keep pull to refresh available in every connected-machine state. A
  /// refresh action only installs a refresh control when it reaches a
  /// supported scroll container, so loading, empty, and unavailable states
  /// each need a real scroll surface rather than a static replacement view.
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
      // Nothing is cached for any machine yet: the one legitimate spinner.
      // Every later launch shows the cached list instead.
      refreshableState(allowsStateHitTesting: false) {
        HomeNavigationSyncView(state: .loading(machineName: "your machines"))
      }
    }
  }

  /// The live sidebar builds its own sections, so Home's body depends on
  /// none of the workspaces it lists. The handler keeps one identity; only
  /// its closures are refreshed here.
  private var sidebarList: some View {
    sidebarActionHandler.actions = sidebarActions
    return HomeSidebarLiveList(
      actions: sidebarActionHandler,
      splitNavigation: layoutMode == .split ? navigation : nil
    )
  }

  #if DEBUG
    /// Fixture navigation with local reordering and no fleet mutations.
    var sampleSidebar: some View {
      HomeSidebarSampleData.Sidebar()
    }
  #endif

  /// Mail-style empty state: the navigation title already supplies the
  /// context, so the body needs only a quiet confirmation that it is empty.
  var emptyState: some View {
    Text("No Workspaces")
      .font(.title3.weight(.bold))
      .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
