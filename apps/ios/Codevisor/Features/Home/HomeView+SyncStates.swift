import CodevisorCore
import SwiftUI

extension HomeView {
  var settingsButton: some View {
    Button {
      presentedSettingsDestination = .root
    } label: {
      Label("Settings", systemImage: "gearshape")
    }
  }

  var machineConnectionWarningButton: some View {
    Button(action: openFailedMachineSettings) {
      Label("Machine connection issues", systemImage: "exclamationmark.icloud")
    }
    .accessibilityHint("Opens Machines settings")
  }

  var failedSyncMachines: [CodevisorMachine] {
    machines.allMachines.filter { machine in
      if case .stale = machines.navigationSyncStateByMachineId[machine.id] { return true }
      return false
    }
  }

  private var presentation: HomeNavigationPresentation {
    navigationPresentation ?? .current(in: environment)
  }

  var launch: NavigationPresentation.Launch { presentation.launch }

  var syncIndicator: NavigationPresentation.SyncIndicator { presentation.syncIndicator }

  func openFailedMachineSettings() {
    let failed = failedSyncMachines
    presentedSettingsDestination = .machines(
      focusedMachineID: failed.count == 1 ? failed[0].id : nil
    )
  }

  func refreshableState<Content: View>(
    allowsStateHitTesting: Bool = true,
    @ViewBuilder content: @escaping () -> Content
  ) -> some View {
    List {
      EmptyView()
    }
    .listStyle(.plain)
    .scrollContentBackground(.hidden)
    .background(Color(.systemBackground))
    .refreshable {
      await refreshNavigation()
    }
    .overlay {
      content()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(allowsStateHitTesting)
    }
  }

  func refreshNavigation() async {
    await machines.refreshNavigation()
  }
}
