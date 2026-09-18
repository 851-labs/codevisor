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
    if !sidebarSections.isEmpty {
      sidebarList
        .overlay {
          syncOverlayIfCatchingUp
        }
    } else if anyMachineSynced {
      // At least one machine answered with a real (empty) list: the
      // honest presentation is "no workspaces"; the toolbar flags sync failures.
      refreshableState(allowsStateHitTesting: false) {
        emptyState
      }
    } else if !failedSyncMachines.isEmpty {
      // Keep the list blank instead of showing stale cached rows.
      // The toolbar warning opens machine settings with the failure details.
      refreshableState(allowsStateHitTesting: false) {
        EmptyView()
      }
    } else if initialSyncDeadlineExpired {
      refreshableState {
        HomeNavigationSyncView(
          state: .failed(machineName: failedSyncMachineNames),
          retry: {
            initialSyncDeadlineExpired = false
            retryFailedMachines()
          }
        )
      }
    } else if initialSyncPending {
      // Nothing cached yet: the one legitimate spinner — and even it
      // may not outlive its budget.
      refreshableState(allowsStateHitTesting: false) {
        HomeNavigationSyncView(
          state: .loading(machineName: failedSyncMachineNames)
        )
      }
      // Constant identity: the clock starts when the branch appears
      // and survives machine-list churn (cloud statuses landing used
      // to recreate the task and reset the budget forever).
      .task(id: "initial-sync-deadline") {
        initialSyncDeadlineExpired = false
        try? await Task.sleep(for: .seconds(15))
        guard !Task.isCancelled else { return }
        initialSyncDeadlineExpired = true
      }
    } else {
      refreshableState(allowsStateHitTesting: false) {
        emptyState
      }
    }
  }

  private var sidebarList: some View {
    HomeSidebarList(
      sections: sidebarSections,
      actions: sidebarActions,
      refresh: refreshNavigation
    )
  }
  
  /// Shows a non-intrusive sync overlay when catching up with buffered events
  @ViewBuilder
  private var syncOverlayIfCatchingUp: some View {
    if let catchingUpMachine = machines.allMachines.first(where: { machine in
      if case .catchingUp = machines.navigationSyncStateByMachineId[machine.id] {
        return true
      }
      return false
    }) {
      let bufferedCount: Int = {
        if case let .catchingUp(count) = machines.navigationSyncStateByMachineId[catchingUpMachine.id] {
          return count
        }
        return 0
      }()
      
      NavigationSyncOverlay(
        machineName: catchingUpMachine.name,
        bufferedEvents: bufferedCount
      )
    }
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
