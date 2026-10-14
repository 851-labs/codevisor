import CodevisorCore
import SwiftUI

struct HomeNavigationPresentation: Equatable {
  var launch: NavigationPresentation.Launch
  var syncIndicator: NavigationPresentation.SyncIndicator

  @MainActor
  static func current(in environment: AppEnvironment) -> Self {
    let knownMachineIDs = Set(environment.machines.allMachines.map(\.id))
    let hasVisibleContent = environment.navigationStore.workspaceEntries.sidebar.contains {
      knownMachineIDs.contains($0.serverId)
    }
    return HomeNavigationPresentation(
      launch: environment.navigationLaunch(hasVisibleContent: hasVisibleContent),
      syncIndicator: environment.navigationSyncIndicator(hasVisibleContent: hasVisibleContent)
    )
  }
}

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
