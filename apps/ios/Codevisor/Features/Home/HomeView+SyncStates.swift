import CodevisorCore
import SwiftUI

/// The home screen's sync-state presentation: navigation visibility, the
/// connection warning, and the refreshable surface used by loading, empty,
/// and unavailable states.
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

  /// Machines whose last completed sync attempt failed, including retries
  /// in progress, surfaced together in the toolbar.
  var failedSyncMachines: [CodevisorMachine] {
    machines.allMachines.filter { machine in
      if case .stale = machines.navigationSyncStateByMachineId[machine.id] { return true }
      return false
    }
  }

  /// What Home shows, from what the device already knows: cached content
  /// right away, a spinner only when nothing is cached anywhere, and
  /// "No Workspaces" only once every machine has said so. Precomputed by
  /// `HomeNavigationPresentationObserver`; only the very first body, before
  /// its first value lands, derives it here.
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

  /// Keep state content fixed over the same native list surface used when
  /// rows exist. The list owns refresh and rubber-band scrolling; the
  /// overlay stays centered in the visible viewport instead of moving with
  /// the scroll content.
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
