import CodevisorCore
import SwiftUI

/// What Home shows from what the device already knows -- the launch state and
/// the toolbar's sync indicator -- as one precomputed value.
///
/// Both derive from the navigation store's caches, which change on every
/// navigation event. Home holds the last value instead of reading them in its
/// body; `HomeNavigationPresentationObserver` recomputes it and hands over a
/// new one only when it actually changed.
struct HomeNavigationPresentation: Equatable {
  var launch: NavigationPresentation.Launch
  var syncIndicator: NavigationPresentation.SyncIndicator

  @MainActor
  static func current(in environment: AppEnvironment) -> Self {
    // "No Workspaces" only once every machine has said so: any listed
    // workspace on a machine this device knows counts as content.
    let knownMachineIDs = Set(environment.machines.allMachines.map(\.id))
    let hasVisibleContent = environment.navigationStore.workspaceEntries.sidebar.contains {
      knownMachineIDs.contains($0.serverId)
    }
    return HomeNavigationPresentation(
      launch: environment.navigationLaunch(hasVisibleContent: hasVisibleContent),
      syncIndicator: environment.navigationSyncIndicator
    )
  }
}

/// Observes the stores behind `HomeNavigationPresentation` on Home's behalf,
/// so their per-event churn re-renders this empty view instead of Home.
struct HomeNavigationPresentationObserver: View {
  @Environment(AppEnvironment.self) private var environment
  let onChange: (HomeNavigationPresentation) -> Void

  var body: some View {
    Color.clear
      .onChange(of: HomeNavigationPresentation.current(in: environment), initial: true) { _, presentation in
        onChange(presentation)
      }
  }
}
